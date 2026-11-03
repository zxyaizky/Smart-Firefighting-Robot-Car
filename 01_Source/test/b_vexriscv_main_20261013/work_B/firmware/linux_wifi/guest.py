"""Send commands to the loopback build VM, never to board COM ports."""
from pathlib import Path
import argparse,socket,sys,time

if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    p=argparse.ArgumentParser();p.add_argument('command');p.add_argument('--seconds',type=int,default=5)
    a=p.parse_args();r=Path(__file__).resolve().parents[2]/'reports/linux_wifi_20261021'
    with socket.create_connection(('127.0.0.1',18991),timeout=5) as s:
        s.settimeout(1);s.sendall(a.command.encode()+b'\n');deadline=time.monotonic()+a.seconds
        with (r/'builder_serial.log').open('ab',buffering=0) as log:
            while time.monotonic()<deadline:
                try:data=s.recv(65536)
                except socket.timeout:continue
                if not data:break
                log.write(data);print(data.decode(errors='replace'),end='',flush=True)
