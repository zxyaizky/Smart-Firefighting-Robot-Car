"""LD14P map frames, matching NAV/map_protocol.h explicit little-endian encoding."""
import hashlib
import struct

HEADER = b'\xaa\x55'
MAP_SIZE = 201
MAX_POINTS = 300
MAX_PAYLOAD = 13 + 2 * MAX_POINTS
MAX_STATIC_BYTES = 1024 * 1024


def decode_frame(frame):
    if len(frame) < 6 or frame[:2] != HEADER:
        raise ValueError('AA55 header or minimum frame size')
    length = int.from_bytes(frame[2:4], 'little')
    if not 1 <= length <= MAX_PAYLOAD or len(frame) != length + 5:
        raise ValueError('payload length')
    checksum = 0
    for byte in frame[2:-1]:
        checksum ^= byte
    if checksum != frame[-1]:
        raise ValueError('XOR checksum')
    if frame[4] != 2:
        if frame[4] == 3 and length != 1:
            raise ValueError('reset frame length')
        return {'type': frame[4], 'bytes': len(frame)}
    if length < 13:
        raise ValueError('point metadata length')
    typ, rx, ry, yaw, vy, vx, wz, n = struct.unpack_from('<BBBhhhhH', frame, 4)
    if n > MAX_POINTS or length != 13 + 2 * n:
        raise ValueError('point count/length mismatch')
    if rx >= MAP_SIZE or ry >= MAP_SIZE or any(v >= MAP_SIZE for v in frame[17:-1]):
        raise ValueError('grid coordinate outside 0..200')
    return dict(type=typ, bytes=len(frame), rx=rx, ry=ry, yaw_mrad=yaw,
                vy_mm_s=vy, vx_mm_s=vx, wz_mrad_s=wz, points=n,
                robot_x_mm=(rx-100)*50, robot_y_mm=(ry-100)*50)


def validate_file(data):
    if not data or len(data) > MAX_STATIC_BYTES:
        raise ValueError('static file must contain 1..1048576 bytes')
    frames = []
    offset = 0
    while offset < len(data):
        if data[offset:offset+2] != HEADER or offset+4 > len(data):
            raise ValueError(f'header/truncated frame at byte {offset}')
        length = int.from_bytes(data[offset+2:offset+4], 'little')
        frame = data[offset:offset+length+5]
        try:
            fields = decode_frame(frame)
        except ValueError as error:
            raise ValueError(f'byte {offset}: {error}') from error
        frames.append(fields)
        offset += len(frame)
    return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                frames=frames, point_frames=sum(f['type'] == 2 for f in frames),
                points=sum(f.get('points', 0) for f in frames))
