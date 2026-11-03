"""Pack a Wi-Fi RAM candidate, preserving the existing Flash layout and files."""
from pathlib import Path
import gzip,hashlib,importlib.util,json,shutil
F=Path(__file__).resolve().parent;O=F/'build';B=F.parent/'linux_boot'
spec=importlib.util.spec_from_file_location('wifi_base_pack',B/'pack.py')
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
sha=lambda data:hashlib.sha256(data).hexdigest()

def validate_rootfs(data):
    at=0;entries={};data=gzip.decompress(data)
    while at<len(data):
        assert data[at:at+6]==b'070701','Expected newc rootfs'
        fields=[int(data[at+6+i*8:at+14+i*8],16) for i in range(13)]
        start=at+110
        name=data[start:start+fields[11]-1].decode().removeprefix('./')
        start=(start+fields[11]+3)&~3
        entries[name]=(fields[1],data[start:start+fields[6]])
        at=(start+fields[6]+3)&~3
        if name=='TRAILER!!!':break
    for name in ['sbin/wifi-start','etc/init.d/rcS','sbin/pppd','sbin/wifi-seed',
                 'bin/busybox','sbin/dropbearmulti']:
        assert entries[name][0]&0o111==0o111,'Not executable in rootfs: '+name
    for name,source in [('sbin/wifi-start','linux/wifi-start'),('etc/init.d/rcS','linux/rcS')]:
        assert entries[name][1]==(F/source).read_bytes(),'Stale rootfs script: '+name

def main():
    validate_rootfs((O/'rootfs.cpio.gz').read_bytes())
    cfg=(O/'kernel.config').read_text()
    for option in ['CONFIG_32BIT=y','CONFIG_MMU=y','CONFIG_RISCV_SBI=y','CONFIG_PPP=y',
                   'CONFIG_PPP_ASYNC=y','CONFIG_UNIX98_PTYS=y','CONFIG_HVC_RISCV_SBI=y']:
        assert option in cfg.splitlines(),option
    for option in ['CONFIG_SMP=y','CONFIG_FPU=y','CONFIG_RISCV_ISA_C=y','CONFIG_RISCV_ISA_V=y']:
        assert option not in cfg.splitlines(),option
    for name in ['busybox','busybox.config','client_key.openssh','client_key.pub','host_key.pub']:
        shutil.copyfile(F.parent/'linux_network/build'/name,O/name)
    image=(O/'Image').read_bytes();header=base.validate_image(image)
    firmware=(O/'fw_jump_wifi.bin').read_bytes();assert len(firmware)<0x2000
    bundle=firmware.ljust(base.KERNEL-base.LOAD,b'\0')+image
    (O/'linux_uart.bin').write_bytes(bundle)
    elf={name:base.validate_elf((O/name).read_bytes()) for name in ['vmlinux','busybox','pppd','wifi-seed']}
    names=['Image','vmlinux','kernel.config','pppd','wifi-seed','rootfs.cpio.gz','linux_uart.bin','board.dtb','fw_jump_wifi.bin']
    records={name:dict(bytes=(O/name).stat().st_size,sha256=sha((O/name).read_bytes())) for name in names}
    result=dict(status='BUILT_NOT_BOARD_TESTED',load_address=base.LOAD,entry=base.ENTRY,
        kernel_address=base.KERNEL,header=header,elf=elf,records=records,
        sbi_sha256=sha(firmware),estimated_uart_seconds=len(bundle)*10*68/64/115200,
        required_fpga_project='td_project/camera_to_dsi_display_wifi.al',flash_modified=False,
        ppp='192.168.11.2:192.168.11.1',ssh='192.168.11.2:2222',windows_endpoint='192.168.4.1:2222')
    (O/'manifest.json').write_text(json.dumps(result,indent=2));print('WIFI_RAM_BUNDLE_PACK_PASS',len(bundle))

if __name__=='__main__':main()
