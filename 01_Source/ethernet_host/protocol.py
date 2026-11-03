"""Strict decoder for FPGA RGB565 UDP v3, RGB888 v2 and legacy v1.

No interpolation, resizing or image processing occurs here. Incomplete frames
are discarded. Metadata must agree across every datagram of a frame.
"""
from __future__ import annotations
from collections import OrderedDict
from dataclasses import dataclass, field, asdict
import struct
import time

WIDTH, HEIGHT = 160, 120
FRAME_BYTES = WIDTH * HEIGHT * 3
PACKET_COUNT = 42
VIDEO_WIDTH, VIDEO_HEIGHT = 640, 360


def rgb565_to_rgb888(data):
    # Wire pixels are big-endian; expand bits exactly like the B-board RTL.
    high, low = data[::2], data[1::2]
    rgb = bytearray(len(high) * 3)
    rgb[::3] = high.translate(bytes((v & 248) | (v >> 5) for v in range(256)))
    rgb[2::3] = low.translate(bytes(((v & 31) << 3) | ((v & 31) >> 2) for v in range(256)))
    green_high = high.translate(bytes(((v & 7) << 5) | ((v & 7) >> 1) for v in range(256)))
    green_low = low.translate(bytes((v >> 5) << 2 for v in range(256)))
    rgb[1::3] = bytes(h | l for h, l in zip(green_high, green_low))
    return bytes(rgb)


@dataclass(frozen=True)
class Metadata:
    version: int
    sync_id: int = 0
    bbox_valid: bool = False
    bbox: tuple[int, int, int, int] = (0, 0, 0, 0)
    sync_valid: bool = False
    bbox_source_valid: bool = False
    source_frame_id: int = 0
    bbox_source_frame_id: int = 0
    bbox_result_id: int = 0
    sensor_metadata_valid: bool = False
    heart_rate_valid: bool = False
    spo2_valid: bool = False
    heart_rate_bpm: int = 0
    spo2: int = 0

    @property
    def same_source(self):
        return self.version in (2, 3) and self.bbox_source_valid and self.source_frame_id == self.bbox_source_frame_id


@dataclass(frozen=True)
class Frame:
    frame_id: int
    metadata: Metadata
    rgb: bytes
    peer: tuple[str, int]
    received_at: float
    received_monotonic: float

    @property
    def width(self):
        return VIDEO_WIDTH if self.metadata.version == 3 else WIDTH

    @property
    def height(self):
        return VIDEO_HEIGHT if self.metadata.version == 3 else HEIGHT

    @property
    def display_bbox(self):
        if not self.metadata.bbox_valid:
            return None
        x1, y1, x2, y2 = self.metadata.bbox
        if self.metadata.version != 3:
            return x1, y1, x2, y2
        # The wire bbox stays in 160x120 model coordinates, with 15 padded rows.
        if y2 < 15 or y1 > 104:
            return None
        return x1 * 4, (max(y1, 15) - 15) * 4, (x2 + 1) * 4 - 1, (min(y2, 104) - 14) * 4 - 1

    def describe(self):
        return dict(frame_id=self.frame_id, metadata=asdict(self.metadata),
                    peer=list(self.peer), received_at=self.received_at,
                    width=self.width, height=self.height, channel_order='RGB', bytes=len(self.rgb),
                    network_pixel_format='RGB565' if self.metadata.version == 3 else 'RGB888',
                    bbox_coordinate_size=[WIDTH, HEIGHT], display_bbox=self.display_bbox)


@dataclass
class Statistics:
    datagrams: int = 0
    bytes_received: int = 0
    valid_packets: int = 0
    invalid_packets: int = 0
    filtered_packets: int = 0
    duplicate_packets: int = 0
    incomplete_frames: int = 0
    missing_frames: int = 0
    complete_frames: int = 0
    stale_frames: int = 0


@dataclass
class Pending:
    metadata: Metadata
    started: float
    chunks: dict[int, bytes] = field(default_factory=dict)


def decode_packet(data: bytes):
    if len(data) < 8:
        raise ValueError('包头不足8字节')
    fid, pid, length, flags, version = struct.unpack_from('>HHHBB', data)
    if version not in (0, 2, 3):
        raise ValueError(f'未知协议版本 {version}')
    count = VIDEO_HEIGHT if version == 3 else PACKET_COUNT
    if pid >= count:
        raise ValueError('分包编号超范围')
    expected_length = 1280 if version == 3 else 528 if pid == 41 else 1392
    expected_flags = 1 if pid == 0 else 2 if pid == count - 1 else 0
    header = 24 if version in (2, 3) else 8
    if length != expected_length or len(data) != header + length or flags != expected_flags:
        raise ValueError('包长或首尾标记不正确')
    meta = Metadata(version=version)
    if version in (2, 3):
        sync_id = struct.unpack_from('>H', data, 8)[0]
        valid, x1, y1, x2, y2, mf = data[10:16]
        source_id, bbox_source, result_id, reserved = struct.unpack_from('>HHHH', data, 16)
        sensor_tag = (mf >> 5) == 0b101
        legacy_sensor = (mf & ~3) == 0 and reserved == 0
        if valid not in (0, 1) or not (sensor_tag or legacy_sensor):
            raise ValueError('metadata标记或保留位不正确')
        if valid and (not mf & 2 or not (0 <= x1 <= x2 < WIDTH and 0 <= y1 <= y2 < HEIGHT)):
            raise ValueError('框坐标或框源帧标记不正确')
        meta = Metadata(version, sync_id, bool(valid), (x1, y1, x2, y2),
                        bool(mf & 1), bool(mf & 2), source_id, bbox_source, result_id,
                        sensor_tag, sensor_tag and bool(mf & 0x10),
                        sensor_tag and bool(mf & 0x08),
                        (((mf & 0x04) << 6) | (reserved >> 8)) if sensor_tag else 0,
                        (reserved & 0xff) if sensor_tag else 0)
    return fid, pid, meta, data[header:]


class Assembler:
    def __init__(self, expected_ip='', expected_port=0, timeout=0.8, max_pending=4):
        self.expected_ip, self.expected_port = expected_ip, expected_port
        self.timeout, self.max_pending = timeout, max_pending
        self.stats = Statistics()
        self.pending: OrderedDict[tuple, Pending] = OrderedDict()
        self.last: dict[tuple, tuple[int, float]] = {}

    def expire(self, now=None):
        now = time.monotonic() if now is None else now
        for key, item in list(self.pending.items()):
            if now - item.started >= self.timeout:
                del self.pending[key]
                self.stats.incomplete_frames += 1

    def feed(self, data: bytes, peer: tuple[str, int], now=None):
        now = time.monotonic() if now is None else now
        st = self.stats
        st.datagrams += 1
        st.bytes_received += len(data)
        if ((self.expected_ip and peer[0] != self.expected_ip) or
                (self.expected_port and peer[1] != self.expected_port)):
            st.filtered_packets += 1
            return None
        self.expire(now)
        try:
            fid, pid, meta, payload = decode_packet(data)
        except ValueError:
            st.invalid_packets += 1
            # Do not allow a malformed member to be silently patched into a
            # complete image by other packets of the same pending frame.
            if len(data) >= 2:
                key = (peer, struct.unpack_from('>H', data)[0])
                if key in self.pending:
                    del self.pending[key]
                    st.incomplete_frames += 1
            return None
        st.valid_packets += 1
        key = (peer, fid)
        item = self.pending.get(key)
        if item and item.metadata != meta:
            del self.pending[key]
            st.incomplete_frames += 1
            if pid != 0:
                st.invalid_packets += 1
                return None
            item = None  # A new START can reuse an aborted UDP frame ID.
        if item is None:
            if len(self.pending) >= self.max_pending:
                self.pending.popitem(last=False)
                st.incomplete_frames += 1
            item = Pending(meta, now)
            self.pending[key] = item
        if pid in item.chunks:
            if item.chunks[pid] == payload:
                st.duplicate_packets += 1
            else:
                st.invalid_packets += 1
                st.incomplete_frames += 1
                del self.pending[key]
            return None
        item.chunks[pid] = payload
        count = VIDEO_HEIGHT if meta.version == 3 else PACKET_COUNT
        if len(item.chunks) != count:
            return None
        rgb = b''.join(item.chunks[i] for i in range(count))
        if meta.version == 3:
            rgb = rgb565_to_rgb888(rgb)
        del self.pending[key]
        previous = self.last.get(peer)
        if previous:
            delta = (fid - previous[0]) & 0xffff
            if delta == 0 or delta >= 0x8000:
                # Board reset recovery after a receive gap; within a live
                # stream, late old frames cannot replace a newer picture.
                if now - previous[1] < self.timeout:
                    st.stale_frames += 1
                    return None
            elif delta > 1:
                st.missing_frames += delta - 1
        self.last[peer] = fid, now
        st.complete_frames += 1
        return Frame(fid, meta, rgb, peer, time.time(), now)
