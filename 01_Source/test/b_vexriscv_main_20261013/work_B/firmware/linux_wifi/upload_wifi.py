"""Upload the Wi-Fi RAM image or reconnect to its console; never program Flash."""
from pathlib import Path
import argparse,sys
F=Path(__file__).resolve().parent;W=F.parents[1];R=W/'reports/linux_wifi_20261021'
sys.path.insert(0,str(W/'tools/uart_loader'))
import run_linux,upload

def main():
    sys.stdout.reconfigure(errors='replace')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',default='COM15')
    parser.add_argument('--upload',action='store_true')
    parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args();run_linux.BUILD=F/'build'
    data,manifest=run_linux.image()
    if args.check_only:
        print('WIFI_BUNDLE_VALIDATED_NO_COM',len(data));return
    sys.path.insert(0,str(W/'tools/uart_loader/vendor'))
    import serial,msvcrt
    print('Requires the NEW camera_to_dsi_display_wifi FPGA bit in SRAM.')
    print('Keep U33 Flash unchanged. Close other COM15 tools. ESP firmware uses a different COM port.')
    with serial.Serial(args.port,115200,timeout=.02,write_timeout=3,xonxoff=False,rtscts=False,dsrdtr=False) as port:
        if args.upload:
            print('COM opened. NOW press B-board global reset ONCE; wait for DDR32 PASS.',flush=True)
            with (R/'board_loader.log').open('wb',buffering=0) as log:
                def emit(data):log.write(data);print(data.decode(errors='replace'),end='',flush=True)
                run_linux.wait_for_rom(port,emit)
            print('Upload minimum %.1f minutes, plus ACK and DDR CRC; keep power and USB connected.'%(manifest['estimated_uart_seconds']/60),flush=True)
            last=-1
            def progress(done,total):
                nonlocal last
                percent=done*100//total
                if percent!=last:print('Sent %d/%d (%d%%)'%(done,total,percent),flush=True);last=percent
            upload.upload(port,data,manifest['load_address'],manifest['entry'],progress)
            print('DDR CRC VERIFIED. Linux Wi-Fi candidate is starting.',flush=True)
        else:print('Monitor only; no reset or upload. Press Enter for B-wifi#.',flush=True)
        run_linux.terminal(port,msvcrt,R/'board_console.log',append=True)

if __name__=='__main__':
    try:main()
    except KeyboardInterrupt:print('Serial closed; board keeps running.')
    except (OSError,ValueError,RuntimeError) as exc:print('ERROR:',str(exc),file=sys.stderr);raise SystemExit(1)
