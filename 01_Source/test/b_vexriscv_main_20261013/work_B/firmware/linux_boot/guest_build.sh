#!/bin/sh
# Linux build host only; never executes TD, accesses COM or programs an FPGA.
set -eu
cd /build
cd /inputs
sha256sum -c <<'EOF'
5f1c4c546660a6a81046fdfa6195306bad2c8d17c0d69876dc100a85ad4613ac  linux-6.12.58.tar.xz
b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314  busybox-1.36.1.tar.bz2
a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4  musl-1.2.5.tar.gz
3ce0c9f16547e5d61b32e0d226926e9a2552ef4b91fccf7ab5ea1a623a77824b  ziglang-0.13.0-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.musllinux_1_1_x86_64.whl
EOF
cd /build
export LC_ALL=C
export KBUILD_BUILD_TIMESTAMP='2024-11-01 00:00:00'
export KBUILD_BUILD_USER=anlu
export KBUILD_BUILD_HOST=portable-builder
apk add --no-cache build-base bison flex bc perl python3 clang llvm lld openssl-dev elfutils-dev unzip cpio xz
mkdir -p /build/src /build/out /build/zig
cd /build/zig
unzip -q -o /inputs/ziglang-0.13.0-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.musllinux_1_1_x86_64.whl
chmod +x ziglang/zig
cd /build/src
test -d linux-6.12.58 || tar -xJf /inputs/linux-6.12.58.tar.xz
test -d busybox-1.36.1 || tar -xjf /inputs/busybox-1.36.1.tar.bz2
test -d musl-1.2.5 || tar -xzf /inputs/musl-1.2.5.tar.gz
echo BUILD_INPUTS_READY
mkdir -p /build/clang-resource/lib/linux /build/clang-resource/lib/baremetal
RESOURCE=$(clang -print-resource-dir)
ln -sfn "$RESOURCE/include" /build/clang-resource/include
/build/zig/ziglang/zig build-lib /build/zig/ziglang/lib/compiler_rt.zig \
    -target riscv32-freestanding -mcpu=generic_rv32+m+a+zicsr+zifencei \
    -O ReleaseSmall -femit-bin=/build/compiler_rt.a
cp /build/compiler_rt.a /build/clang-resource/lib/linux/libclang_rt.builtins-riscv32.a
cp /build/compiler_rt.a /build/clang-resource/lib/baremetal/libclang_rt.builtins-riscv32.a
cd /build/src/musl-1.2.5
CC='clang --target=riscv32-linux-musl -march=rv32ima_zicsr_zifencei -mabi=ilp32 -fuse-ld=lld' \
    AR=llvm-ar RANLIB=llvm-ranlib LIBCC=/build/compiler_rt.a \
    ./configure --target=riscv32-linux-musl --prefix=/build/sysroot --disable-shared
make -j4
make install
cp /inputs/rv32_cc.py /build/rv32-cc
chmod +x /build/rv32-cc
cd /build/src/busybox-1.36.1
make allnoconfig
python3 - <<'PY'
from pathlib import Path
import re
p=Path('.config')
s=p.read_text()
for line in Path('/inputs/busybox.fragment').read_text().splitlines():
    if '=' in line and line.startswith('CONFIG_'):
        key=line.split('=')[0]
        s=re.sub(r'^(?:'+key+r'=.*|# '+key+r' is not set)$',line,s,flags=re.M)
p.write_text(s)
PY
yes '' | make oldconfig >/build/out/busybox-oldconfig.log
make -j4 CC=/build/rv32-cc HOSTCC=cc AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
    EXTRA_CFLAGS='-Os -mno-relax'
cp busybox /build/out/busybox
cp .config /build/out/busybox.config
mkdir -p /build/rootfs/bin /build/rootfs/sbin /build/rootfs/etc/init.d \
    /build/rootfs/proc /build/rootfs/sys /build/rootfs/dev /build/rootfs/tmp /build/rootfs/root
cp busybox /build/rootfs/bin/busybox
/build/rv32-cc -Os -ffreestanding -fno-builtin -nostdlib -static -Wl,-e,_start \
    /inputs/user_check.c -o /build/rootfs/bin/linux-check
cd /build/rootfs
ln -sf bin/busybox init
for app in sh cat ls mount umount mkdir echo uname dmesg free ps uptime sleep; do
    ln -sf busybox bin/$app
done
test -c dev/console || mknod -m 600 dev/console c 5 1
test -c dev/null || mknod -m 666 dev/null c 1 3
printf 'root:x:0:0:root:/root:/bin/sh\n' >etc/passwd
printf 'root:x:0:\n' >etc/group
printf '::sysinit:/etc/init.d/rcS\nhvc0::respawn:/bin/sh -il\n' >etc/inittab
cat >etc/init.d/rcS <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
if ! /bin/linux-check; then
    echo 'LINUX USER CHECK FAILED: stopping startup'
    while :; do sleep 60; done
fi
echo
echo 'ANLU LINUX USERSPACE READY'
echo 'RV32IMA / Sv32 / one hart / SBI hvc0 / 32 MiB CPU DDR'
echo 'Try: uname -a ; free ; cat /proc/cpuinfo ; uptime'
echo 'RAM rootfs only. Flash/network/SSH are not enabled.'
echo
EOF
chmod 755 etc/init.d/rcS
printf 'export HOME=/root\nexport PATH=/bin:/sbin\nexport PS1="B-linux# "\ncd /root\n' >etc/profile
find . -print0 | sort -z | cpio --null -o --format=newc | gzip -n -9 >/build/out/rootfs.cpio.gz
cd /build/src/linux-6.12.58
make ARCH=riscv LLVM=1 KCONFIG_ALLCONFIG=/inputs/kernel.fragment allnoconfig
make ARCH=riscv LLVM=1 -j4 Image
cp arch/riscv/boot/Image /build/out/Image
cp vmlinux /build/out/vmlinux
cp .config /build/out/kernel.config
{ clang --version; ld.lld --version; /build/zig/ziglang/zig version; uname -a; } >/build/out/tool_versions.txt
python3 /inputs/send_artifacts.py
echo BUILD_COMPLETE
