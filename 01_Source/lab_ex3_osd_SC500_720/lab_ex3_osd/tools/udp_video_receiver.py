#!/usr/bin/env python3
"""Receive and display the FPGA 160x120 RGB888 UDP video stream."""

from __future__ import annotations

import argparse
from collections import deque
import socket
import struct
import time

import cv2
import numpy as np


FRAME_WIDTH = 160
FRAME_HEIGHT = 120
FRAME_BYTES = FRAME_WIDTH * FRAME_HEIGHT * 3
HEADER_BYTES = 8
FULL_IMAGE_PAYLOAD = 1392
LAST_IMAGE_PAYLOAD = 528
LAST_PACKET_ID = 41
FLAG_FIRST = 0x01
FLAG_LAST = 0x02


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Display 160x120 RGB888 frames sent by the FPGA."
    )
    parser.add_argument("--bind-ip", default="192.168.137.1")
    parser.add_argument("--port", type=int, default=6001)
    parser.add_argument("--scale", type=int, default=4)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sock.bind((args.bind_ip, args.port))
    sock.settimeout(0.5)

    active_frame_id: int | None = None
    expected_packet_id = 0
    frame_data = bytearray()
    last_completed_frame_id: int | None = None
    received_frames = 0
    dropped_frames = 0
    start_time = time.monotonic()
    frame_times: deque[float] = deque()

    print(f"Listening on {args.bind_ip}:{args.port}; press Esc in the window to exit")
    cv2.namedWindow("FPGA UDP Video", cv2.WINDOW_NORMAL)

    while True:
        try:
            datagram, _source = sock.recvfrom(2048)
        except socket.timeout:
            if cv2.waitKey(1) == 27:
                break
            continue

        if len(datagram) < HEADER_BYTES:
            dropped_frames += active_frame_id is not None
            active_frame_id = None
            frame_data.clear()
            continue

        frame_id, packet_id, payload_len, flags, reserved = struct.unpack(
            ">HHHBB", datagram[:HEADER_BYTES]
        )
        payload = datagram[HEADER_BYTES:]

        packet_valid = (
            reserved == 0
            and payload_len == len(payload)
            and payload_len % 3 == 0
            and packet_id <= LAST_PACKET_ID
        )
        expected_length = (
            LAST_IMAGE_PAYLOAD if packet_id == LAST_PACKET_ID else FULL_IMAGE_PAYLOAD
        )
        packet_valid = packet_valid and payload_len == expected_length

        if packet_id == 0:
            if active_frame_id is not None:
                dropped_frames += 1
            if not packet_valid or not (flags & FLAG_FIRST):
                active_frame_id = None
                frame_data.clear()
                continue
            if (
                last_completed_frame_id is not None
                and frame_id != ((last_completed_frame_id + 1) & 0xFFFF)
            ):
                print(
                    f"frame_id jump: {last_completed_frame_id} -> {frame_id}; "
                    "starting at the new complete-frame candidate"
                )
            active_frame_id = frame_id
            expected_packet_id = 0
            frame_data.clear()

        if (
            active_frame_id is None
            or frame_id != active_frame_id
            or packet_id != expected_packet_id
            or not packet_valid
        ):
            if active_frame_id is not None:
                dropped_frames += 1
            active_frame_id = None
            frame_data.clear()
            continue

        should_be_last = packet_id == LAST_PACKET_ID
        if bool(flags & FLAG_LAST) != should_be_last:
            dropped_frames += 1
            active_frame_id = None
            frame_data.clear()
            continue

        frame_data.extend(payload)
        expected_packet_id += 1

        if should_be_last:
            if len(frame_data) != FRAME_BYTES:
                dropped_frames += 1
                active_frame_id = None
                frame_data.clear()
                continue

            rgb = np.frombuffer(frame_data, dtype=np.uint8).reshape(
                FRAME_HEIGHT, FRAME_WIDTH, 3
            )
            bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
            if args.scale > 1:
                bgr = cv2.resize(
                    bgr,
                    (FRAME_WIDTH * args.scale, FRAME_HEIGHT * args.scale),
                    interpolation=cv2.INTER_NEAREST,
                )
            received_frames += 1
            now = time.monotonic()
            frame_times.append(now)
            while frame_times and frame_times[0] < now - 2.0:
                frame_times.popleft()
            if len(frame_times) >= 2:
                display_fps = (len(frame_times) - 1) / max(
                    frame_times[-1] - frame_times[0], 1e-9
                )
            else:
                display_fps = received_frames / max(now - start_time, 1e-9)
            cv2.setWindowTitle(
                "FPGA UDP Video",
                f"FPGA UDP Video | frame={frame_id} "
                f"rx={received_frames} drop={dropped_frames} "
                f"fps={display_fps:.2f}",
            )
            cv2.imshow("FPGA UDP Video", bgr)
            last_completed_frame_id = frame_id
            active_frame_id = None
            frame_data.clear()
            # Service the GUI once per completed frame. Calling waitKey for all
            # 42 packets throttles reception and can overflow the UDP buffer.
            if cv2.waitKey(1) == 27:
                break

    sock.close()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
