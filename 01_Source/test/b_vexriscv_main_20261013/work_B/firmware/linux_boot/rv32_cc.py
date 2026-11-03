#!/usr/bin/python3
"""RV32IMA Clang driver using the locally built musl and freestanding builtins."""
import os,sys
arguments=[]
for argument in sys.argv[1:]:
    if argument.startswith('-Wp,-MD,'):
        arguments.extend(['-MD','-MF',argument[len('-Wp,-MD,'):]])
    else:
        arguments.append(argument)
flags=['clang','--target=riscv32-linux-musl','-march=rv32ima_zicsr_zifencei',
       '-mabi=ilp32','--sysroot=/build/sysroot','-isystem','/build/sysroot/include',
       '-L/build/sysroot/lib','-fuse-ld=lld','-fno-stack-protector']
if not any(a in arguments for a in ['-c','-E','-S','-nostdlib','-r']):
    # This C-only static executable needs musl's actual CRT and compiler helpers,
    # not the host Clang distribution's GCC crtbegin/SSP defaults.
    flags+=['-nostdlib','/build/sysroot/lib/crt1.o','/build/sysroot/lib/crti.o']
    arguments+=['-Wl,--start-group','-lc','/build/compiler_rt.a',
                '-Wl,--end-group','/build/sysroot/lib/crtn.o']
os.execvp('clang',[*flags,*arguments])
