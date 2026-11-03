#!/bin/sh
set -eu
ip link set eth0 up
udhcpc -i eth0 -q
printf 'http://10.0.2.2:18990/apk/v3.22/main\nhttp://10.0.2.2:18990/apk/v3.22/community\n' >/etc/apk/repositories
mkdir -p /inputs /build
command -v mkfs.ext4 >/dev/null || apk add --no-cache e2fsprogs
# /dev/vda is the new builder.qcow2 file attached by builder.py, never a host disk.
if ! blkid /dev/vda | grep -q 'TYPE="ext4"'; then
    mkfs.ext4 -L ANLU_BUILD /dev/vda
fi
modprobe ext4
mountpoint -q /build || mount -t ext4 /dev/vda /build
mkdir -p /build/out
cd /inputs
for file in linux-6.12.58.tar.xz busybox-1.36.1.tar.bz2 musl-1.2.5.tar.gz \
    ziglang-0.13.0-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.musllinux_1_1_x86_64.whl; do
    wget -q -O "$file" "http://10.0.2.2:18990/cache/$file"
done
for file in guest_build.sh kernel.fragment busybox.fragment rv32_cc.py send_artifacts.py user_check.c; do
    wget -q -O "$file" "http://10.0.2.2:18990/$file"
done
(set +e; sh /inputs/guest_build.sh; echo $? >/build/out/exit_code) >/build/out/build.log 2>&1 &
echo BUILD_STARTED
