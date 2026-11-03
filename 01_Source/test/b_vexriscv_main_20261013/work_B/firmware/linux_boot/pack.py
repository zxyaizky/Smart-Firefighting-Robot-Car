"""Pack the accepted SBI and a real RV32 Linux Image for the existing ROM loader."""
from pathlib import Path
import hashlib, json, struct

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OUT=HERE/'build'
LOAD,ENTRY,KERNEL,LIMIT=0x40100000,0x40100000,0x40400000,0x41fff000

def sha(data):
    return hashlib.sha256(data).hexdigest()

def validate_elf(data):
    if len(data)<52 or data[:6]!=b'\x7fELF\x01\x01':
        raise ValueError('Expected little-endian ELF32')
    header=struct.unpack_from('<16sHHIIIIIHHHHHH',data)
    if header[1]!=2 or header[2]!=243 or header[7]!=0:
        raise ValueError('Expected RV32 executable, no RVC/RVE/float ABI')
    for i in range(header[10]):
        typ=struct.unpack_from('<I',data,header[5]+i*header[9])[0]
        if typ==3:
            raise ValueError('Unexpected dynamic interpreter: rootfs must be self-contained')
    return dict(machine=header[2],flags=header[7],entry=header[4])

def validate_image(image):
    if len(image)<64 or image[56:60]!=b'RSC\x05':
        raise ValueError('Missing Linux RISC-V Image header')
    offset,size,flags=struct.unpack_from('<QQQ',image,8)
    version=struct.unpack_from('<I',image,32)[0]
    if offset!=0x400000 or flags&1 or version!=2:
        raise ValueError('Expected little-endian RV32 Image v0.2 with 4 MiB text offset')
    if not len(image)<=size<=0x2000000-(KERNEL-0x40000000):
        raise ValueError('Kernel including BSS does not fit the CPU 32 MiB window')
    if KERNEL+len(image)>LIMIT:
        raise ValueError('Kernel overlaps the loader reserved top of RAM')
    return dict(text_offset=offset,image_size=size,flags=flags,version=version)

def main():
    manifest=json.loads((ROOT/'firmware/vexriscv_sbi/build/manifest.json').read_text())
    firmware=(ROOT/'firmware/vexriscv_sbi/build/fw_jump.bin').read_bytes()
    assert sha(firmware)==manifest['records']['fw_jump']['sha256']
    assert len(firmware)<0x2000
    image=(OUT/'Image').read_bytes()
    header=validate_image(image)
    binaries={name:validate_elf((OUT/name).read_bytes()) for name in ['vmlinux','busybox']}
    cfg=(OUT/'kernel.config').read_text()
    for option in ['CONFIG_32BIT=y','CONFIG_MMU=y','CONFIG_RISCV_SBI=y',
                   'CONFIG_RISCV_SBI_V01=y','CONFIG_HVC_RISCV_SBI=y','CONFIG_BINFMT_ELF=y',
                   'CONFIG_RISCV_MISALIGNED=y','CONFIG_RISCV_PROBE_UNALIGNED_ACCESS=y']:
        assert option in cfg.splitlines(),option
    for option in ['CONFIG_64BIT=y','CONFIG_SMP=y','CONFIG_FPU=y','CONFIG_RISCV_ISA_C=y','CONFIG_RISCV_ISA_V=y']:
        assert option not in cfg.splitlines(),option
    # Keep the existing ROM protocol and proven SBI unchanged. Zero padding costs
    # UART transfer time; a compact Flash layout belongs to the later Flash step.
    bundle=firmware.ljust(KERNEL-LOAD,b'\0')+image
    (OUT/'linux_uart.bin').write_bytes(bundle)
    records={name:dict(bytes=(OUT/name).stat().st_size,sha256=sha((OUT/name).read_bytes()))
             for name in ['Image','vmlinux','busybox','rootfs.cpio.gz','kernel.config','busybox.config','linux_uart.bin']}
    record=dict(status='BUILT_NOT_BOARD_TESTED',linux='6.12.58',busybox='1.36.1',
                load_address=LOAD,entry=ENTRY,kernel_address=KERNEL,header=header,elf=binaries,
                sbi_sha256=sha(firmware),records=records,estimated_uart_seconds=len(bundle)*10*68/64/115200)
    (OUT/'manifest.json').write_text(json.dumps(record,indent=2))
    print(json.dumps(record,indent=2))

if __name__=='__main__':
    main()
