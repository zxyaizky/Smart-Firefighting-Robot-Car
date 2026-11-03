# 双目系统第 2 阶段实施记录

状态：7 个行为 testbench 全部 PASS；新增核心编译零错误、零告警。A 全工程静态编译通过；B 全工程保留已复核的原有 DDR wrapper 编译错误，详见后文。未进行综合、布线、下载。

本阶段只实现 GPIO 请求、源帧身份传递、右目干净 RGB、独立 bbox metadata 和 UDP v2 检查。没有增加左右目图像 Frame RAM，没有实现 SAD、视差、距离、测距 OSD 或小车控制。原有图像 FIFO、DDR 存储和红框模块保留。

## 工程与文件清单

- A：`C:\Users\lx292\Desktop\lab_ex3_osd_SC500_720\lab_ex3_osd`
- B：`C:\Users\lx292\Desktop\test\lab_ex3_osd_SC500_720P\lab_ex3_osd`

以下清单以本轮开始时的文件为基准，不把原工程已有修改计入本轮。

### 板卡 A

新增：

- [td_project/import/stereo_sync_rx.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/stereo_sync_rx.v)
- [td_project/import/stereo_frame_selector.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/stereo_frame_selector.v)
- [td_project/import/stereo_page_metadata.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/stereo_page_metadata.v)
- [td_project/import/stereo_metadata_mailbox.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/stereo_metadata_mailbox.v)
- [td_project/import/stereo_metadata_fifo.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/stereo_metadata_fifo.v)
- [sim/stereo_stage2/tb_stereo_sync_selector.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/sim/stereo_stage2/tb_stereo_sync_selector.v)
- [sim/stereo_stage2/tb_stereo_udp.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/sim/stereo_stage2/tb_stereo_udp.v)
- [sim/stereo_stage2/tb_stereo_identity.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/sim/stereo_stage2/tb_stereo_identity.v)
- [sim/stereo_stage2/tb_stereo_bbox.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/sim/stereo_stage2/tb_stereo_bbox.v)
- [sim/stereo_stage2/run_stereo_stage2.py](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/sim/stereo_stage2/run_stereo_stage2.py)
- [doc/stereo_stage2.md](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/doc/stereo_stage2.md)

修改：

- [user_source/constraints_source/pin.adc](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/user_source/constraints_source/pin.adc)
- [user_source/hdl_source/design_top_wrapper.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/user_source/hdl_source/design_top_wrapper.v)
- [user_source/hdl_source/video_in.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/user_source/hdl_source/video_in.v)
- [user_source/hdl_source/video_out.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/user_source/hdl_source/video_out.v)
- [td_project/camera_to_dsi_display.al](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/camera_to_dsi_display.al)
- [td_project/camera_to_dsi_display.sdc](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/camera_to_dsi_display.sdc)
- [td_project/import/ethernet_video_tx_top.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/ethernet_video_tx_top.v)
- [td_project/import/npu_bbox_overlay_160x120.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/npu_bbox_overlay_160x120.v)
- [td_project/import/npu_rgb_input.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/npu_rgb_input.v)
- [td_project/import/npu_video_input.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/npu_video_input.v)
- [td_project/import/video_udp_tx.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import/video_udp_tx.v)
- [sim/tb_video_udp_tx.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/sim/tb_video_udp_tx.v)
- [sim/tb_npu_bbox_threshold.v](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/sim/tb_npu_bbox_threshold.v)

### 板卡 B

新增：

- [td_project/import/stereo_sync_gen.v](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/td_project/import/stereo_sync_gen.v)
- [td_project/import/stereo_metadata_fifo.v](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/td_project/import/stereo_metadata_fifo.v)
- [sim/tb_stereo_sync_gen.v](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/sim/tb_stereo_sync_gen.v)

修改：

- [user_source/constraints_source/pin.adc](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/user_source/constraints_source/pin.adc)
- [user_source/hdl_source/design_top_wrapper.v](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/user_source/hdl_source/design_top_wrapper.v)
- [td_project/camera_to_dsi_display.al](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/td_project/camera_to_dsi_display.al)
- [td_project/import/ethernet_video_rx_top.v](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/td_project/import/ethernet_video_rx_top.v)
- [td_project/import/video_udp_rx.v](C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd/td_project/import/video_udp_rx.v)

仿真产物集中在 A 的 `sim/stereo_stage2/`，包括各 `.log`、`results.json`、`changes.json`、ModelSim 工作库与源文件列表。它们不加入 FPGA 工程。B 的同步发生器 testbench 位于 B 的 `sim/`。

## GPIO 与复位约定

根据用户提供的引脚汇总 DOCX，GPIOA_1 为 FPGA V1、排针第 2 脚。两板都把 V1 用作本阶段同步 GPIO：B `stereo_sync_o` → A `stereo_sync_i`，并连接公共 GND，电平为 LVCMOS33。B 原有 GPIOA_0/V2 小车串口保持原样。这里只更新约束，没有实际接线或下载。

B 使用 50 MHz 系统时钟，`CLK_FREQ=50000000`、`SYNC_RATE=5`、`PULSE_CYCLES=50000`：周期 200 ms，高电平宽度 1 ms，默认低。复位时 ID=0；复位释放后等待完整一个周期，第一次请求 ID=1。每个请求 ID 只增加一次，`stereo_sync_event_o` 保持一个本地时钟周期，GPIO 保持多个周期。计数器 16 bit 自然回绕。

A 在 CSI 时钟域使用两级同步器和上升沿检测，每个接收边沿本地 ID 加一。选择器等待下一次 `S_csi_frame_start`；新请求与 CSI SOF 同周期时归属下一次 SOF。仅有一个 pending 槽，多次请求未消费时使用最新 ID，并输出 overrun。未选中帧 `sync_valid=0`、`sync_id=0`。

## 源帧身份，不按延迟猜测

原工程已有四页 DDR 写指针 `S_video_in_wp`、读指针 `O_video_out_rp`，没有可从 CSI 一直传到 UDP 的 capture/source frame ID。因此新增最小页标签，复用实际页寻址机制。

1. 每个 CSI SOF 给原始源帧 `source_frame_id` 加一，选中帧同时记录 sync ID。这个 ID 是摄像头源帧号，与 UDP 发送号不同。
2. 后续 RAW `S_raw_tuser` 在同一 CSI 时钟域捕获 `{sync_valid, sync_id, source_frame_id}` 33 bit，并保持整个源帧。RAW 标记位于 CSI SOF 之后，捕获的是该帧已经更新的选择器输出。
3. 在 `video_in.S_frame_start` 的 DDR 时钟边沿，将标签写到与 DDR 写基地址相同的页：正常写页是更新前 `S_video_in_wp`；错误重写分支与原地址映射一致，为 `wp-1`。每页标签仅 33 bit，加一个 complete 位。
4. 新页先标为 incomplete；只有观察到完整的 172800 个 128-bit RGB 写字（1280×720×3÷16）才标为 complete。摄像头 FIFO overflow 或新 SOF 与旧 DDR 写突发重叠，标签失效，不向采样器提交该页。这里的完整性是写字计数与这些已接入错误条件，不等同于 MIPI 全链路完整性验证。
5. `video_out` 在选定 DDR 读基址的同一个 SOF 边沿，快照同一 `I_video_out_rp` 的页标签，通过 34-bit request/ack mailbox 送到 HDMI 像素时钟域。之后的读指针变化不会改写正在显示帧的身份。每次新 VS 先清除旧有效标志；未到达新标签时采样器跳过整帧。
6. 两个 `npu_video_input` 都设置 `REQUIRE_METADATA=1`，在 VS 后第一个对齐的有效 RGB 像素开始采样，让像素与页身份同时被采样器接受。源采样位置仍为 `(8u,8v)`，u=0..159、v=0..89。
7. `npu_rgb_input` 用一个 33-bit 保持寄存器及 START token 的应答传递身份；新 START 必须等待旧 START 已消费。原有 256×26-bit 像素 token FIFO 没有扩宽。重复显示同一 DDR 源帧时，source ID/sync ID 保持相同。

新增存储仅有四页标签、窄 metadata mailbox、每个 TX/RX 各一个 4×128-bit metadata FIFO（当前 full 判定保留一个槽）以及少量寄存器。没有存储双目图像的新 Frame RAM。FIFO 指定 distributed RAM 属性；实际资源映射和使用率本阶段未综合，不能给出硬件实现数值。

## A→B 数据链路

```text
B 50 MHz stereo_sync_gen
  ├─ stereo_sync_event / sync_id（保留，后续用于左目锁帧）
  └─ V1 GPIO OUT → A V1 GPIO IN
                      ↓ 两级同步、边沿、计数
                  stereo_frame_selector @ CSI SOF
                      ↓ 源帧号 / sync_id
A CSI → RAW10 → ISP → video_in → 原有四页 DDR → video_out 干净 RGB888
                   └─ 每页 metadata ───────────→ 当前读页 metadata
                                                       ↓
                             两个独立 npu_video_input / npu_rgb_input
                               ├─ NPU 分支 → YOLO → bbox 解码 + bbox 源帧号
                               └─ UDP 分支 → 160×90 → npu_rgb_frame_tap
                                                       ↓ 上下各 15 黑行
                                                   160×120 RGB888
                                                       ├─ 原有红框显示支路（保留）
                                                       └─ RAW RGB + metadata 快照
                                                          ↓ video_udp_tx v2
                                                          ↓ 原有 UDP/Ethernet TX
                                                        Ethernet
                                                          ↓ 原有 Ethernet/UDP RX
                                                       B video_udp_rx v2
                                                          ↓
                      frame_start / pixel_valid / RGB / frame_end / frame_abort
                      udp_frame_id / source_frame_id / sync_id / bbox 及其源帧号
```

UDP 的五个输入帧边界/像素信号都接 `S_udp_*_raw`，RGB 明确接 `S_udp_pixel_rgb_raw`。保留 `npu_bbox_overlay_160x120`，直接导出其解码寄存器，不扫描红色像素。干净图像指与原始输入像素完全一致；真实场景本来为 `FF2020` 的像素也可以正常传输。

## UDP v2 固定 24-byte 头

选择 24 byte 是为了同时明确传输 sync、当前源帧、bbox 源帧和结果序号。所有 16-bit 字段使用大端；每包重复同一份 metadata。旧 8-byte 协议不再被 B 的 v2 RX 接受。

| 字节 | 字段 | 规则 |
|---|---|---|
| 0–1 | udp_frame_id | 原有成功发送帧序号，首帧为 0；不是 CSI 帧号或 sync ID |
| 2–3 | packet_id | 0..41 |
| 4–5 | image_length | 本包 RGB 字节数；普通包 1392，尾包 528；不是整帧长度 |
| 6 | flags | bit0 首包、bit1 尾包，其余为 0；首包 01、中间 00、尾包 02 |
| 7 | version | 02 |
| 8–9 | sync_id | GPIO 请求对应的本地计数 ID，仅 flags15.bit0=1 时用于配对 |
| 10 | bbox_valid | 00 或 01，是否有有效检测框 |
| 11 | bbox_x1 | 0..159 |
| 12 | bbox_y1 | 0..119，最高位必须为 0 |
| 13 | bbox_x2 | 0..159 |
| 14 | bbox_y2 | 0..119，最高位必须为 0 |
| 15 | metadata_flags | bit0 sync_valid；bit1 bbox_source_valid；bit7..2=0 |
| 16–17 | source_frame_id | 当前 RGB 对应的 CSI 源帧号 |
| 18–19 | bbox_source_frame_id | 产生此 bbox/无检测结果的 NPU 输入源帧号 |
| 20–21 | bbox_result_id | 每次发布推理结果加一，复位 0；首次结果 1 |
| 22–23 | reserved | 0000 |
| 24 起 | RGB888 | R、G、B 字节，逐行，共 19200 像素/57600 字节 |

每帧仍为 42 包：41×464 像素 + 176 像素。普通 UDP payload 为 1416 byte，尾包为 552 byte。每帧 UDP payload 合计 58608 byte。相较原头增加 16×42=672 byte/帧，约为原 payload 的 1.16%；60 fps 时增加约 0.323 Mbit/s。若只增加用户示例中的 8 byte，则为 336 byte/帧，但不能同时装下全部帧关联字段。

TX 在接受 RAW raster START 时原子快照完整 metadata，此后推理输出变化不修改当前帧的任何包。使用独立小 metadata FIFO 跟随 START，未扩宽原有图像 FIFO。

B 检查版本、包长、首尾 flags、源 UDP port、坐标范围、保留位、frame ID、packet ID 和整份 128-bit metadata 一致性。有效框必须有有效源帧号且 x1≤x2/y1≤y2。错误包导致 abort，后续包不能把该帧补成有效 END。RX 先拿到 START 的 metadata，再输出 pixel-domain frame_start；元数据在这一帧的像素期间保持稳定。只在完整收到 19200 像素且正常 END 后更新 completed_frame_id/count。

`S_eth_rx_frame_id` 表示正在接收的 UDP 帧，`S_eth_rx_completed_frame_id` 表示最近完成帧，两者语义不同。当前 `frame_start/pixel_valid` 仍是流式输出，部分像素可以先到达；未来消费者必须把 frame_end 当提交条件，把 frame_abort 当废弃条件。没有为了本阶段增加图像暂存 RAM。

## bbox 与视频帧关联

NPU 分支受 busy 门控，UDP 分支一直独立采样；两者不会保证每个显示帧都同时被接受。二者各自从相同 DDR 读页标签获取真实 source_frame_id。

在 NPU `frame_valid` 上升且 `!S_npu_input_busy` 时锁存推理源帧号，这与现有 `npu_network_top` 的输入 admission 条件一致。被 busy 拒绝的输入不会改写正在推理的源帧号。直到下一次被接受的输入，源帧号保持不变。在 inference_done 时将这个源帧号与 decode_valid 一起送入 bbox 的坐标流水线，与最终坐标/valid/result_id 同时发布。现有错误信号会阻止把失败推理发布为新结果。没有改写 NPU 网络和计算内核。

每个 UDP 帧可以携带最近的已发布 bbox，但明确标出 bbox_source_frame_id。只有 bbox_source_valid=1 且 bbox_source_frame_id==source_frame_id 时，才能认为是当前右目源帧的结果。不同表示旧帧结果，不能当作当前帧的目标。bbox_valid=0 且 bbox_source_valid=1 表示某个已知源帧的无检测结果；两个 valid 都为 0 表示复位后尚无推理结果。框坐标属于补黑边后的 160×120 坐标系，后续若映射到有效区需处理 15 行边距。

当前没有缓存过去的右目图像来等待其 YOLO 结果，所以只保证关联可核对，不保证每幅当前右目图都能配到同源 bbox。16-bit source ID 回绕或跨独立复位时，没有额外 epoch 字段，不能凭数值相等跨 epoch 配对。

## 仿真与静态检查

使用 ModelSim SE-64 2020.4 的 vlib/vlog/vsim；没有调用 FPGA 工具流。复现命令：

```powershell
python "C:\Users\lx292\Desktop\lab_ex3_osd_SC500_720\lab_ex3_osd\sim\stereo_stage2\run_stereo_stage2.py"
```

| Testbench | 结果 | 覆盖 |
|---|---|---|
| tb_stereo_sync_gen | PASS | 周期 20 个仿真时钟、宽度 4、单周期 event、每脉冲一次 ID、65535→0 回绕、复位重启 |
| tb_stereo_sync_selector | PASS | 异步 GPIO、两级同步、长脉冲只计一次、下一 CSI SOF、pending 最新请求、请求与 SOF 同周期、复位 |
| tb_stereo_udp | PASS | TX→RX 独立时钟、sync=1234、bbox=(40,30)-(90,80)、42 包、全部 57600 RGB 字节及头部字节序、SOF 后 metadata 变化不影响本帧 |
| tb_stereo_udp 错误场景 | PASS | packet_id、sync_id、bbox、udp_frame_id、source_frame_id、version 错误，以及短包；均不提交 frame_end/completed；源 abort 后新完整帧恢复 |
| tb_stereo_identity | PASS | CSI 标签→页→真实 video_out 地址/metadata mailbox→真实采样器→tap；两个完整 1280×720 raster，逐像素检查 (8u,8v)、补黑边、重复源帧、无效页拒绝、overflow/跨帧突发标签失效 |
| tb_stereo_bbox | PASS | 真实坐标解码直接输出、源帧号随坐标流水线原子更新、result_id、无检测结果源关联、复位 |
| tb_video_udp_tx | PASS | 更新原 testbench 为 RAW RGB/24-byte 头，6 个完整帧、57600 字节逐字节比较、42 包、FIFO stall/drop 恢复、约 60 fps |
| tb_npu_bbox_threshold | PASS | 原阈值检测回归，obj≥64/fire≥128；补齐新增端口 |

上述是 7 个独立行为 testbench，全部零仿真错误、零告警。编译核心模块也为零错误、零告警。identity test 的 vendor FIFO 为 simulation-only 端口 stub；它不模拟真实 DDR 图像写读、PHY 或 FIFO 时序。页标签测试使用 FRAME_WORDS=4 缩短写计数，实际采样 raster 为完整 1280×720；RTL 默认 FRAME_WORDS=172800。没有运行完整硬件 NPU 推理、真实 RGMII PHY 或摄像头仿真。

A 全部 108 个 active project Verilog 静态编译：0 error，80 warning；告警均来自原有 HDMI encrypted wrapper 的冗余数值位宽。修改前 A 备份编译也是 0 error/80 warning。

B 全部 97 个 active project Verilog 静态编译：1 个原有 error，80 个相同类型的原有 HDMI warning：`user_source/hdl_source/ph1p35_ddr/ph1p35_324_ddr_wrapper.v:61` 引用未声明的 `dhi_clk`。本轮开始的 B 备份完全复现同一 error/80 warning；该 wrapper 的 SHA-256 未改变。本阶段不改动这个 DDR wrapper，不能把 B 全工程静态编译写成通过。新增/修改的阶段核心模块编译和 7 个行为测试均通过。

A/B 新增/修改模块的命名端口连接检查分别覆盖 13/4 个实例；active 文件存在、无重复；V1 分配各一次；静态确认 TX 五个输入均为 RAW 支路；两板小 metadata FIFO 内容一致。相对于本轮备份的哈希检查确认 B video_in/video_out、HDMI/OSD、Ethernet HDMI framebuffer、小车模块及其他 HDL 均未修改。没有新综合/布线报告，因此原工程资源数字不能当作本次实现的资源使用率。

## 仍然存在的限制

- GPIO 是“下一源帧选择请求”，没有驱动两颗传感器曝光/帧同步。自由运行的 A/B 摄像头仍可能存在接近一个源帧周期的相位差；不能称为硬件曝光同步。B 本阶段只产生事件，尚未实现左目采样、配对控制或匹配计算。
- A/B ID 依赖同一个复位 epoch、相同初值及每个 GPIO 脉冲恰好接收一次。没有把 ID 从 GPIO 传输，没有丢脉冲校验、复位握手或 epoch 恢复。A CSI 时钟必须运行才能接收脉冲。跨域 FIFO/mailbox 也遵循成对复位约定，独立域中途复位恢复未验证。
- 每个 pending 只有一个槽，多个请求到来时最新覆盖旧请求。5 Hz 默认远慢于 60 fps，但摄像头停顿时仍可能发生覆盖。
- 选中的 CSI 帧不保证必然被 video_out 读出或通过 Ethernet 发到 B。DDR 页调度、完整性失效、采样器 busy、FIFO 背压或网络丢包都可能使 sync ID 对应图像缺失；重复显示同一页也可能发出重复 source/sync ID。必须依据接收的有效 ID 配对，不能按发送次数或固定延时推断。
- 只新增协议校验与整帧提交规则，没有 UDP ACK、重传、重新排序缓存或超时。源端 abort 是 TX 本地 token，不单独发送网络 abort 包；已经发出的部分帧会在下一首包或错误包到来时被 B abort。若尾包丢失且再无任何包，B 不提交完整帧，但也不会定时主动产生 abort。
- MIPI/ISP 故障检测没有整体重构。原顶层 I_mipi_rx_error 仍接 0；页完整性目前覆盖已接入写字计数、摄像头 FIFO overflow、跨 SOF DDR 突发条件，不是对所有图像语义错误的保证。
- 实际引脚、电平、布局时序、同步器硬件可靠性和资源映射尚未进行板上验证或综合 STA；这是用户要求的本阶段边界。

本阶段到此结束，不继续编写双目匹配代码。
