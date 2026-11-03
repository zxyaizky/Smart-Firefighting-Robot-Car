# 160x120 NPU Ethernet video integration

Date: 2026-09-20

This change is RTL and RTL-simulation only. Synthesis, implementation, bitstream
generation, and resource estimation were not run.

## Actual image path

The board top reads clean RGB888 from `video_out.O_vdieo_data` using
`S_video_rd_data`. `npu_video_input` aligns the registered RGB with the read
enable. `npu_rgb_input` samples the center pixel of each 8x8 source block:

```text
target_x = dx * 8 + 4, dx=0..159
target_y = dy * 8 + 4, dy=0..89
```

The resulting 14,400 pixels cross into the current 100 MHz NPU clock domain and are
emitted as interleaved R, G, B bytes on `S_npu_byte`. Only after this point does
`lbp_to_ping_packer` place the bytes into CHW addresses. It first clears all
3,600 128-bit PING words, which creates 15 black rows above and below the sampled
160x90 image.

The Ethernet branch uses a separate `npu_video_input` instance with its busy
input tied low. It shares the same display RGB source and sampling rule as the
NPU but has an independent 256-entry token FIFO, so inference busy no longer
limits Ethernet video to the inference frame rate. `npu_rgb_frame_tap`
reconstructs RGB pixels and explicitly generates the same 15+90+15 padded
160x120 raster.

## Detection and OSD

The current detector does not expose a separate `class_id/valid/x1/y1/x2/y2`
bus. Its final reduced tensor is:

```text
{gy, gx, fire, h, w, dy, dx, obj}
```

`npu_bbox_overlay_160x120` decodes this tensor directly in the NPU coordinate
system, applies the display-tuned `obj >= 64` and `fire >= 128` validity thresholds as
the HDMI overlay, clips to 160x120, and draws a one-pixel red rectangle. No text
or confidence value is drawn.

## CDC and packetization

`video_udp_tx` writes 26-bit START/PIXEL/END/ABORT tokens in the 100 MHz NPU
domain. `video_udp_async_fifo` crosses them to the Ethernet 125 MHz domain using
Gray-coded pointers and two-flop pointer synchronizers. FIFO depth is 4,096
tokens. Almost-full reserves eight entries so an abort marker can be written.

The packetizer buffers a complete image chunk before requesting the verified
UDP stack, because that stack requires continuous payload valid after accepting
a request. A normal frame has 42 packets:

- packets 0..40: 1,392 RGB bytes plus 8 application-header bytes = 1,400 bytes;
- packet 41: 528 RGB bytes plus 8 application-header bytes = 536 bytes.

All 16-bit header fields are network byte order (high byte first):

```text
Byte 0..1  frame_id
Byte 2..3  packet_id
Byte 4..5  RGB payload length (1392 or 528)
Byte 6     bit0=first packet, bit1=last packet
Byte 7     reserved, zero
Byte 8..   R, G, B, R, G, B, ...
```

`frame_id` advances only after packet 41 completes. An almost-full/full or
source abort condition emits an ABORT token, discards the damaged frame, and
waits for the next START token. Partial packets already sent retain the old
`frame_id`; the PC receiver discards them and resets when the next packet zero
arrives.

## Ethernet integration

`ethernet_video_tx_top` contains the renamed Ethernet PLL/reset wrappers,
`video_udp_tx`, the copied verified `uiudp_stack`, and the copied verified
`rgmii_interface`. The configuration is:

```text
FPGA 192.168.137.2:6002
PC   192.168.137.1:6001
MAC  01:23:45:67:89:ab
```

The Ethernet protocol/RGMII core source was copied without logic changes.
Only the outer `pll` and `uiphyrst` module names were changed to `eth_pll` and
`eth_phy_reset` to keep ownership clear.

## Ethernet pin assignment

The verified Ethernet reference constraint file assigns:

```text
O_a_rgmii_tx_ctl -> R10
O_a_rgmii_txd[0] -> R11
```

The NPU project already assigns:

```text
I_rst_n      -> R10
O_screen_pwm -> R11
```

The HX1P35B board pin table confirms that R10 and R11 are the fixed on-board
Ethernet PHY pins. The integration therefore moves the active-low design reset
to the unused KEY1 pin D5 and removes the constant-high `O_screen_pwm` top-level
port. The complete RGMII/PHY constraint block from the verified Ethernet
reference design is merged into `pin.adc`; in particular, `O_a_rgmii_txd[2]`
is constrained to the HDIO-compatible T10 pin required by the existing
`PH1P_LOGIC_HD_ODDR` implementation.

## PC receiver

Install dependencies and run:

```text
python -m pip install numpy opencv-python
python lab_ex3_osd/tools/udp_video_receiver.py
```

The receiver binds `192.168.137.1:6001`, enforces packet order and exact lengths,
requires all 57,600 bytes, converts RGB to OpenCV BGR, and never displays a
partial frame. GUI event processing runs once per completed frame rather than
once per UDP packet, avoiding 42 artificial waits per frame. The title reports
a rolling two-second FPS value.

## RTL simulation

See `sim/video_udp_tx_sim_report.md`. The self-check passed pixel/byte counts,
RGB order, bbox pixel insertion, frame and packet IDs, packet lengths, final
packet length, busy handshake, no FIFO underflow/write-overflow, whole-frame
drop on almost-full, and recovery on the following frame.
