"""Upload one raw RV32 binary, verify DDR readback, then execute it.

Protocol v1: l -> VRDL READY, header+CRC -> K,
each <=64 payload bytes+CRC -> K, whole-image DDR CRC -> V then jump.
No retry is sent after ambiguous/failed ACK: reset before another attempt.
"""
from pathlib import Path
import argparse
import struct
import sys
import time
import zlib

LOAD_MIN, LOAD_LIMIT = 0x40010000, 0x41fff000
DEFAULT_ADDRESS = 0x40100000
PACKET_BYTES = 64
MAGIC = b'VRD1'
ERRORS = {b'H': 'header/magic CRC', b'R': 'address/length/entry range',
          b'C': 'packet or DDR image CRC', b'T': 'receive timeout',
          b'U': 'UART framing/overflow', b'E': 'DDR access or program exception'}


def crc(data):
    return struct.pack('<I', zlib.crc32(data) & 0xffffffff)


def validate(length, address, entry):
    if not LOAD_MIN <= address < LOAD_LIMIT or address & 3:
        raise ValueError('Load address must be aligned and within 0x40010000..0x41ffefff')
    if not 4 <= length <= LOAD_LIMIT - address:
        raise ValueError('Image exceeds reserved CPU DDR space or is shorter than 4 bytes')
    if entry & 3 or not address <= entry <= address + length - 4:
        raise ValueError('Entry must be 4-byte aligned with a full instruction inside the image')


def make_header(image, address=DEFAULT_ADDRESS, entry=None):
    entry = address if entry is None else entry
    validate(len(image), address, entry)
    body = struct.pack('<4sIIII', MAGIC, address, len(image), entry, zlib.crc32(image) & 0xffffffff)
    return body + crc(body)


def frames(image):
    for offset in range(0, len(image), PACKET_BYTES):
        payload = image[offset:offset+PACKET_BYTES]
        yield payload + crc(payload)


def expect(port, expected, timeout, stage):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        actual = port.read(1)
        if not actual:
            continue
        if actual == expected:
            return
        reason = ERRORS.get(actual, 'unexpected response ' + repr(actual))
        raise RuntimeError(stage + ': ' + reason + '; reset the board before retrying')
    raise TimeoutError(stage + ': no response; reset before retrying (do not resend a packet)')


def send(port, data):
    if port.write(data) != len(data):
        raise IOError('Incomplete serial write; reset before retrying')
    port.flush()


def upload(port, image, address=DEFAULT_ADDRESS, entry=None, progress=None):
    header = make_header(image, address, entry)
    port.reset_input_buffer()
    send(port, b'l')
    banner = bytearray()
    deadline = time.monotonic() + 3
    while not banner.endswith(b'VRDL READY\r\n'):
        if time.monotonic() >= deadline or len(banner) > 512:
            raise TimeoutError('No VRDL READY: use the NEW loader bit and finish DDR selftest first')
        banner.extend(port.read(1))
    send(port, header)
    expect(port, b'K', 3, 'header')
    completed = 0
    for packet in frames(image):
        send(port, packet)
        expect(port, b'K', 3, 'packet at byte '+str(completed))
        completed += len(packet)-4
        if progress:
            progress(completed, len(image))
    expect(port, b'V', max(10, len(image)/50000), 'DDR readback verification')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path, help='raw RV32 binary; ELF is not accepted')
    parser.add_argument('--port', required=True, help='e.g. COM15')
    parser.add_argument('--address', type=lambda v: int(v, 0), default=DEFAULT_ADDRESS)
    parser.add_argument('--entry', type=lambda v: int(v, 0))
    parser.add_argument('--monitor', action='store_true', help='show program output until Ctrl+C')
    args = parser.parse_args()
    # Validate everything before opening a real port or sending the loader command.
    size = args.image.stat().st_size
    validate(size, args.address, args.address if args.entry is None else args.entry)
    with args.image.open('rb') as file:
        image = file.read()
    if image.startswith(b'\x7fELF'):
        raise ValueError('Use an objcopy-produced .bin, not an ELF executable')
    sys.path.insert(0, str(Path(__file__).resolve().parent/'vendor'))
    try:
        import serial
    except ImportError:
        raise RuntimeError('Install pyserial==3.5, or use the bundled vendor directory') from None
    print(f'{args.port} 115200 8N1, {len(image)} bytes -> 0x{args.address:08x}')
    print('Close the serial assistant first. Waiting for CPU loader...')
    with serial.Serial(args.port, 115200, timeout=0.2, write_timeout=3,
                       xonxoff=False, rtscts=False, dsrdtr=False) as port:
        last = [-1]
        def progress(done, total):
            percent = done*100//total
            if percent != last[0]:
                print(f'\rSent {done}/{total} bytes ({percent}%)', end='', flush=True)
                last[0] = percent
                if done == total:
                    print('\nAll packets accepted; CPU is verifying DDR readback...', flush=True)
        upload(port, image, args.address, args.entry, progress)
        print('\nDDR CRC verified; CPU is jumping to the uploaded program.')
        if args.monitor:
            print('Program output (Ctrl+C closes the port):')
            while True:
                data = port.read(256)
                if data:
                    print(data.decode('ascii', errors='replace'), end='', flush=True)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nSerial port closed.')
    except (OSError, ValueError, RuntimeError) as error:
        print('ERROR: '+str(error), file=sys.stderr)
        raise SystemExit(1)
