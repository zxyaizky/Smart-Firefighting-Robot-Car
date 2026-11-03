"""Merge only a user-generated lidar FPGA bit with the isolated Linux/old MCU payloads."""
import argparse,hashlib,json,struct,subprocess,sys,zlib
from pathlib import Path
from prepare import D,F,W,R

def inputs():
    manifest=json.loads((D/'build/kernel_manifest.json').read_text())
    assert manifest['status']=='PASS_QEMU_MEMORY_PPP_SSH_BOARD_PENDING'
    payload=(D/'build/linux_flash_package.bin').read_bytes();image=(D/'build/linux_uart.bin').read_bytes()
    assert len(payload)==len(image)+24
    magic,address,length,entry,crc,header_crc=struct.unpack('<4sIIIII',payload[:24])
    assert magic==b'VRD1' and (address,entry)==(0x40100000,0x40100000)
    assert length==len(image) and payload[24:]==image
    assert crc==zlib.crc32(image)&0xffffffff and header_crc==zlib.crc32(payload[:20])&0xffffffff
    assert 0x200000+len(payload)<0xe00000
    assert hashlib.sha256(payload).hexdigest()==manifest['records']['linux_flash_package.bin']['sha256']
    mcu=W/'firmware/linux_wifi_flash/build/u33_boot_fw.bin'
    assert mcu.is_file() and mcu.stat().st_size==32
    return payload,mcu

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bit',type=Path,default=W/'td_project/camera_to_dsi_display_lidar_Runs/best_result/camera_to_dsi_display_lidar.bit')
    p.add_argument('--check-only',action='store_true')
    a=p.parse_args();payload,mcu=inputs()
    if a.check_only:
        print('LIDAR_LINUX_FLASH_INPUTS_PASS_NO_MERGE_OR_PROGRAMMING',len(payload));return
    assert a.bit.is_file(),'First generate the NEW lidar bit in TD; do not select the old wifi_flash bit'
    assert 'lidar' in a.bit.name.lower(),'The input must be the independently generated lidar project bit'
    latest=max(path.stat().st_mtime for path in [*(D/'rtl').glob('*.v'),*(D/'constraints').glob('*.sdc')])
    assert a.bit.stat().st_mtime>=latest,'Bit predates current lidar RTL/constraints; rebuild in TD first'
    target=D/'build/u33_lidar_linux.bit'
    assert not target.exists(),'Keep the existing merged artifact; rename it before making another'
    script=R/'merge_lidar_flash.tcl'
    script.write_text('set rc [catch {create_flash_file -target_file {'+a.bit.resolve().as_posix()+
      '} -added_file {'+(D/'build/linux_flash_package.bin').as_posix()+':200000 '+mcu.as_posix()+
      ':e00000} -output {'+target.as_posix()+'} -rom_size {128M}} message]\nputs $message\nif {$rc} {exit 1}\nexit\n')
    bitworks=next((path for path in [Path('C:/Anlogic/bin/bw_commands_prompt.exe'),
                                    Path('D:/qianrushi/bin/bw_commands_prompt.exe')]
                   if path.is_file()),None)
    assert bitworks is not None,'Bitworks command-line tool not found'
    result=subprocess.run([str(bitworks),script.as_posix()],capture_output=True,timeout=60,creationflags=0x08000000)
    (R/'flash_merge.log').write_bytes(result.stdout+result.stderr)
    assert result.returncode==0 and target.is_file()
    merged=target.read_bytes();offset=merged.find(payload)-0x200000
    assert 0<offset<4096 and merged[offset+0x200000:offset+0x200000+len(payload)]==payload
    assert merged[offset+0xe00000:offset+0xe00000+32]==mcu.read_bytes()
    bit=a.bit.read_bytes();assert merged[offset:len(bit)]==bit[offset:]
    assert len(merged)-offset<=0x1000000
    state=dict(output=str(target),sha256=hashlib.sha256(merged).hexdigest(),bytes=len(merged),container_header_bytes=offset,
      inputs=dict(FPGA=str(a.bit.resolve()),Linux=str(D/'build/linux_flash_package.bin'),MCU=str(mcu)),
      offsets=dict(FPGA='0x00000000',Linux='0x00200000',MCU='0x00e00000'),programming_performed=False)
    (D/'build/flash_merge_manifest.json').write_text(json.dumps(state,indent=2));print(json.dumps(state,indent=2))

if __name__=='__main__':main()
