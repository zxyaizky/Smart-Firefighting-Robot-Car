"""Merge a newly built B Flash-candidate FPGA .bin with Linux and hard-MCU code.

Writes a reviewable host file only. Does not invoke BitWriter or program Flash.
"""
from pathlib import Path
import argparse,hashlib,json,re
import build

def merge(config,payload,firmware):
    if not 65536<=len(config)<=build.FLASH_OFFSET:
        raise ValueError('FPGA config must be 64 KiB..2 MiB; review layout if it is larger')
    if not payload or build.FLASH_OFFSET+len(payload)>build.MCU_OFFSET:
        raise ValueError('Linux payload overlaps MCU firmware')
    if not firmware or build.MCU_OFFSET+len(firmware)>build.FLASH_SIZE:
        raise ValueError('MCU firmware exceeds Flash capacity')
    image=bytearray(b'\xff'*(build.MCU_OFFSET+len(firmware)))
    for offset,data in [(0,config),(build.FLASH_OFFSET,payload),(build.MCU_OFFSET,firmware)]:
        image[offset:offset+len(data)]=data
    return bytes(image)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bitstream',type=Path,required=True,help='NEW camera_to_dsi_display_linux_flash raw configuration .bin')
    args=parser.parse_args()
    if args.bitstream.suffix.lower()!='.bin':raise ValueError('Use TD raw .bin; do not rename a .bit file')
    project=build.W/'td_project/camera_to_dsi_display_linux_flash.al'
    dependencies=[Path(p) for p in re.findall(r'<File Path="([^"]+)"',project.read_text())]
    dependencies += list((build.O/'MCU').glob('*'))
    if args.bitstream.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in dependencies if p.is_file()):
        raise ValueError('FPGA .bin is older than candidate sources. Rebuild the FLASH candidate, not the TIMER bit.')
    meta=json.loads((build.O/'manifest.json').read_text())
    payload=(build.O/'linux_payload.bin').read_bytes()
    if hashlib.sha256(payload).hexdigest()!=meta['regions'][1]['sha256']:
        raise ValueError('Linux payload does not match the CRC compiled into the candidate ROM')
    firmware=(build.O/'u33_boot_fw.bin').read_bytes()
    if len(firmware)!=meta['regions'][2]['bytes'] or hashlib.sha256(firmware).hexdigest()!=meta['regions'][2]['sha256']:
        raise ValueError('MCU firmware hash/length mismatch; rebuild before merging')
    image=merge(args.bitstream.read_bytes(),payload,firmware)
    output=build.O/'u33_linux_flash_image.bin';output.write_bytes(image)
    report=dict(status='MERGED_NOT_PROGRAMMED',file=str(output),bytes=len(image),
        sha256=hashlib.sha256(image).hexdigest(),bitstream=str(args.bitstream.resolve()),
        bitstream_sha256=hashlib.sha256(args.bitstream.read_bytes()).hexdigest(),
        flash_offset=0,regions=meta['regions'],
        limitation='Timestamp checks reject stale files but do not prove which project produced a bitstream; verify the TD build provenance.')
    build.put(build.O/'combined_manifest.json',json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
