"""Upload the validated SBI/DTB acceptance bundle; automatically test SBI RX."""
from pathlib import Path
import argparse,hashlib,json,sys,time
import upload
W=Path(__file__).resolve().parents[2]

def checked_image(path,record):
    image=path.read_bytes()
    if len(image)!=record['bytes'] or hashlib.sha256(image).hexdigest()!=record['sha256']:
        raise ValueError('SBI bundle differs from build/manifest.json; rebuild and validate first')
    if record['address']!=0x40100000 or record['entry']!=0x40100000:
        raise ValueError('Unexpected SBI load address or entry')
    upload.validate(len(image),record['address'],record['entry'])
    return image

def accept(port,emit=print,timeout=15):
    transcript=bytearray();sent=False;deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        data=port.read(64)
        if not data:continue
        emit(data.decode('ascii',errors='replace'))
        transcript.extend(data)
        if len(transcript)>2048:raise RuntimeError('Unexpected SBI serial flood')
        if any(word in transcript for word in [b'FAIL',b'FATAL',b'IMAGE MISSING']):
            raise RuntimeError('CPU rejected SBI/DTB acceptance; save this output and reset')
        if not sent and b'RX TEST>\r\n' in transcript:
            upload.send(port,b'Z');sent=True
        if b'SBI PROBE PASS\r\n' in transcript:
            if not sent:raise RuntimeError('PASS without console RX challenge')
            return bytes(transcript)
    raise TimeoutError('No SBI PROBE PASS; save output and reset before retrying')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',default='COM15');args=parser.parse_args()
    build=W/'firmware/vexriscv_sbi/build'
    record=json.loads((build/'manifest.json').read_text())['records']['sbi_probe']
    image=checked_image(build/'sbi_probe.bin',record)
    sys.path.insert(0,str(Path(__file__).resolve().parent/'vendor'))
    import serial
    print(f'{args.port} 115200 8N1, {len(image)} bytes -> 0x40100000')
    print('Use the TIMER-PASS bit. Close the serial assistant and reset the board first.')
    with serial.Serial(args.port,115200,timeout=0.05,write_timeout=3,
                       xonxoff=False,rtscts=False,dsrdtr=False) as port:
        last=[-1]
        def progress(done,total):
            p=done*100//total
            if p!=last[0]:
                print(f'\rSent {done}/{total} bytes ({p}%)',end='',flush=True);last[0]=p
        upload.upload(port,image,progress=progress)
        print('\nDDR CRC verified; CPU is starting SBI.')
        accept(port,emit=lambda s:print(s,end='',flush=True))
    print('SBI/DTB acceptance passed. Linux kernel has NOT been loaded.')
    print('Serial port closed; CPU keeps running. Reset before another upload.')
if __name__=='__main__':
    try:main()
    except KeyboardInterrupt:print('\nSerial port closed.')
    except (OSError,ValueError,RuntimeError) as error:
        print('ERROR: '+str(error),file=sys.stderr);raise SystemExit(1)
