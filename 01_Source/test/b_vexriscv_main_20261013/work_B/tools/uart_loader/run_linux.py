"""Upload the verified SBI + Linux/initramfs bundle, then use COM as a terminal."""
from pathlib import Path
import argparse, hashlib, json, sys, time
import upload

ROOT=Path(__file__).resolve().parents[2]
BUILD=ROOT/'firmware/linux_boot/build'

def wait_for_rom(port,emit,timeout=120):
    """Listen for the actual reset/selftest menu before sending any command."""
    transcript=bytearray();deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        chunk=port.read(64)
        if not chunk:
            continue
        emit(chunk);transcript.extend(chunk)
        if b'DDR32 FAIL' in transcript:
            raise RuntimeError('ROM reports DDR32 FAIL; upload was not started. Save board_loader_latest.log.')
        if b'DDR32 PASS\r\n> ' in transcript:
            return
        if len(transcript)>65536:
            raise RuntimeError('No ROM menu in received output; upload was not started. Save board_loader_latest.log.')
    detail='No serial bytes received.' if not transcript else 'Received output, but no DDR32 PASS ROM menu.'
    raise TimeoutError(detail+' Upload was not started. Keep the TIMER/SBI-PASS bit, reopen this script and press the global reset key after COM opens. See board_loader_latest.log.')


def image():
    manifest=json.loads((BUILD/'manifest.json').read_text())
    data=(BUILD/'linux_uart.bin').read_bytes()
    record=manifest['records']['linux_uart.bin']
    if len(data)!=record['bytes'] or hashlib.sha256(data).hexdigest()!=record['sha256']:
        raise ValueError('Linux bundle hash/length mismatch; rebuild before uploading')
    if (manifest['load_address'],manifest['entry'],manifest['kernel_address'])!=(0x40100000,0x40100000,0x40400000):
        raise ValueError('Unexpected Linux memory layout')
    upload.validate(len(data),manifest['load_address'],manifest['entry'])
    return data,manifest

def terminal(port,keyboard,log,append=False):
    log.parent.mkdir(parents=True,exist_ok=True)
    with log.open('ab' if append else 'wb',buffering=0) as out:
        while True:
            chunk=port.read(1024)
            if chunk:
                out.write(chunk)
                print(chunk.decode('utf-8',errors='replace'),end='',flush=True)
            if keyboard.kbhit():
                char=keyboard.getwch()
                if char in ('\x00','\xe0'):
                    keyboard.getwch()
                    continue
                if char=='\b':
                    char='\x7f'
                if ord(char)<128:
                    port.write(char.encode('ascii'))
                    # Idle hvc0 can poll only once per 2 seconds; pace input
                    # to fit the unchanged 16-byte hardware RX FIFO.
                    time.sleep(0.15)

def main():
    sys.stdout.reconfigure(errors='replace')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',default='COM15')
    parser.add_argument('--monitor-only',action='store_true',help='Reconnect without reset or upload; append console log')
    args=parser.parse_args()
    if not args.monitor_only:
        data,manifest=image()  # Validate before opening COM or issuing loader commands.
    sys.path.insert(0,str(Path(__file__).resolve().parent/'vendor'))
    import serial
    import msvcrt
    log=ROOT/'reports/linux_boot_20261020/board_console_latest.log'
    if args.monitor_only:
        print(f'{args.port} 115200 8N1, terminal only; no reset or upload.')
        print('Keep the board powered. Close other serial tools. Do NOT press reset.')
        print('Earlier output cannot be recovered. If Linux is already running, press Enter for its prompt. Ctrl+C closes the port.')
        with serial.Serial(args.port,115200,timeout=0.02,write_timeout=3,
                           xonxoff=False,rtscts=False,dsrdtr=False) as port:
            terminal(port,msvcrt,log,append=True)
        return
    print(f'{args.port} 115200 8N1, {len(data)} bytes -> 0x40100000')
    print('Keep the TIMER/SBI-PASS bit. Close other serial tools. Do not power-cycle to an older Flash bit.')
    print(f'UART transfer minimum: {manifest["estimated_uart_seconds"]/60:.1f} min; ACK/DDR checks add time.')
    with serial.Serial(args.port,115200,timeout=0.02,write_timeout=3,
                       xonxoff=False,rtscts=False,dsrdtr=False) as port:
        print('COM opened. NOW press the B-board GLOBAL RESET key once; waiting up to 120 seconds for the ROM menu.',flush=True)
        startup_log=ROOT/'reports/linux_boot_20261020/board_loader_latest.log'
        with startup_log.open('wb',buffering=0) as out:
            def received(chunk):
                out.write(chunk)
                print(chunk.decode('ascii',errors='replace'),end='',flush=True)
            wait_for_rom(port,received)
        print('\nROM DDR32 PASS confirmed. Requesting the loader and starting upload.',flush=True)
        last=-1
        def progress(done,total):
            nonlocal last
            percentage=done*100//total
            if percentage!=last:
                print(f'\rSent {done}/{total} ({percentage}%)',end='',flush=True)
                last=percentage
            if done==total:
                print(f'\nAll packets accepted. CPU is verifying the whole DDR image CRC (timeout {max(10,total/50000):.0f} s).',flush=True)
                print('100% is NOT CRC success. Keep waiting; do not press Ctrl+C or reset.',flush=True)
        try:
            upload.upload(port,data,manifest['load_address'],manifest['entry'],progress)
        except KeyboardInterrupt:
            print('\nHost waiting interrupted; DDR CRC/jump has NOT been confirmed.')
            print('If 100% was already reached, keep power on and run monitor_linux.cmd without reset to check subsequent output.')
            print('For a fresh upload, run run_linux.cmd and reset only after COM opens.')
            return
        print('\nDDR CRC verified. Starting SBI -> Linux. Ctrl+C closes this terminal.')
        print('Wait for ANLU LINUX USERSPACE READY, then try: uname -a')
        terminal(port,msvcrt,log)

if __name__=='__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nSerial port closed. Reconnect with monitor_linux.cmd without reset; reset only for a fresh upload.')
    except (OSError,ValueError,RuntimeError) as error:
        print('ERROR: '+str(error),file=sys.stderr)
        raise SystemExit(1)
