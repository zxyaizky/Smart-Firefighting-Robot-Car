#!/usr/bin/env python3
"""Capture complete, unmodified RGB888 frames from the FPGA UDP video feed."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import socket
import struct
import tempfile
import time

import cv2
import numpy as np


WIDTH = 160
HEIGHT = 120
PACKETS_PER_FRAME = 42
FRAME_BYTES = WIDTH * HEIGHT * 3


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", default="192.168.137.1")
    parser.add_argument("--port", type=int, default=6001)
    parser.add_argument("--frames", type=int, default=6)
    parser.add_argument("--seconds", type=float, default=15.0)
    args = parser.parse_args()

    output = Path(tempfile.mkdtemp(prefix="fpga-udp-camera-"))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sock.bind((args.ip, args.port))
    sock.settimeout(0.5)

    active_id = None
    packets: dict[int, bytes] = {}
    completed = []
    invalid = 0
    incomplete = 0
    deadline = time.monotonic() + args.seconds
    try:
        while len(completed) < args.frames and time.monotonic() < deadline:
            try:
                datagram, source = sock.recvfrom(2048)
            except socket.timeout:
                continue
            if len(datagram) < 8:
                invalid += 1
                continue
            frame_id, packet_id, length, flags, reserved = struct.unpack(
                ">HHHBB", datagram[:8]
            )
            payload = datagram[8:]
            expected_length = 528 if packet_id == 41 else 1392
            if (
                reserved != 0
                or packet_id >= PACKETS_PER_FRAME
                or length != expected_length
                or len(payload) != length
                or bool(flags & 1) != (packet_id == 0)
                or bool(flags & 2) != (packet_id == 41)
            ):
                invalid += 1
                continue
            if active_id != frame_id:
                if active_id is not None and len(packets) != PACKETS_PER_FRAME:
                    incomplete += 1
                active_id = frame_id
                packets = {}
            packets[packet_id] = payload
            if packet_id != 41:
                continue
            if len(packets) != PACKETS_PER_FRAME:
                incomplete += 1
                active_id = None
                packets = {}
                continue
            raw = b"".join(packets[i] for i in range(PACKETS_PER_FRAME))
            if len(raw) != FRAME_BYTES:
                invalid += 1
                active_id = None
                packets = {}
                continue
            rgb = np.frombuffer(raw, np.uint8).reshape(HEIGHT, WIDTH, 3)
            filename = output / f"frame_{frame_id:05d}.png"
            if not cv2.imwrite(str(filename), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)):
                raise RuntimeError(f"could not save {filename}")
            completed.append({"frame_id": frame_id, "source": source[0],
                              "file": str(filename), "bytes": len(raw)})
            print(f"CAPTURED frame={frame_id} source={source[0]} file={filename}",
                  flush=True)
            active_id = None
            packets = {}
    finally:
        sock.close()

    report = {"output": str(output), "frames": completed,
              "invalid_packets": invalid, "incomplete_frames": incomplete}
    (output / "capture.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
