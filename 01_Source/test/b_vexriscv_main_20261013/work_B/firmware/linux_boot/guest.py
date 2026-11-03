"""Send a command only to the isolated build VM's loopback serial console."""
from pathlib import Path
import argparse, socket, sys, time

if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8',errors='replace')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command')
    parser.add_argument('--seconds',type=int,default=50)
    args=parser.parse_args()
    report=Path(__file__).resolve().parents[2]/'reports/linux_boot_20261020'
    with socket.create_connection(('127.0.0.1',18991),timeout=5) as s:
        s.settimeout(1)
        s.sendall(args.command.encode()+b'\n')
        deadline=time.monotonic()+args.seconds
        with (report/'builder_serial.log').open('ab',buffering=0) as f:
            while time.monotonic()<deadline:
                try:
                    b=s.recv(65536)
                except socket.timeout:
                    continue
                if not b:
                    break
                f.write(b)
                print(b.decode(errors='replace'),end='',flush=True)
