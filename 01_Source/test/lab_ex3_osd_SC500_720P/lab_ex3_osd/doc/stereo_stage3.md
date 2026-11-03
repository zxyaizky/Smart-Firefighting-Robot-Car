# 双目第 3 阶段：B 本地左目数据准备

日期：2026-10-02。实施对象：`C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd`。

第 3.5 阶段后续状态：A 清单已只补回五个缺失条目，精确恢复第 2 阶段结束时 SHA256；七项第 2 阶段回归全 PASS，drift 已 RESOLVED。本文第 9 节保留原始观察，当前结果见 [第 3.5 阶段报告](C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd/doc/stereo_stage3p5.md)。

已实现 B 本地请求选帧、DDR 页身份传播、干净 RGB 的严格相位采样和 Gray8 流输出。只进行了 ModelSim 行为仿真与静态编译。没有运行 FPGA 综合、布局布线或下载，没有新增左/右目图像 Frame RAM、SAD、视差、距离或配对控制，没有修改小车控制、显示效果或原有 DDR wrapper。

## 1. 修改前的 B 帧身份链

| 用户关注的信号/问题 | 修改前的实际行为 |
|---|---|
| `S_capture_frame_id` | 来自 `video_in.O_capture_frame_id`；在 DDR 域 `S_frame_start && !I_mipi_rx_error` 时加 1；复位为 0，第一帧为 1。复用了这一计数器。 |
| 这个边界是什么 | 顶层 `S_raw_tuser = S_axis_tuser` 送到 `I_camera_frame_start`，RAW 标记展宽后跨到 DDR，产生 `~extend_3d & extend_2d`。因此是 **RAW 派生的 DDR capture/写页开始边界**，不是直接 CSI SOF，也不是整页写完事件。 |
| 写页如何传到读页 | `S_page_frame_id[0:3]` 随写指针记录 capture ID。wp=0/1/2/3 时分别写页 0/1/2/3，读候选页为 2/3/0/1。MIPI 错误分支回写 wp-1。 |
| `S_video_out_frame_valid` | 原实现一到 capture 开始便将写页 valid 置 1，没有等待完整 172800 个 128-bit 写数据字；错误回写还可能留下旧候选信息。它不足以证明一张完整页已经可读。 |
| `S_video_rd_data` 属于谁 | `video_out` 在 HDMI VS 派生的 DDR 读帧边界选择页地址，并锁存 `S_display_frame_id_ddr`。RGB 属于这个锁存的读页，而不是随下一次 camera capture 改变的候选 `S_video_out_frame_id`。原有身份跨到系统域用于延迟统计，不能直接作为像素域的原子身份。 |

因此保留本地 capture ID 和四页机制，补齐页完成判定、sync 标签及读帧身份到像素域的传播。没有第二套本地 source frame counter。

## 2. 实施后的数据与身份传播

```text
stereo_sync_gen（50 MHz，原有默认约 5 Hz）
  event + sync_id
       ↓ 16-bit request/ack CDC mailbox
DDR 域 selector 请求队列（4 项 metadata，无图像）
       ↓ 下一次正常 RAW 派生 capture 边界
existing O_capture_frame_id + 1
       ↓ 在同一个边沿绑定 sync_id + source_frame_id
video_in 同一写页的 page_frame_id / page_sync_valid / page_sync_id
       ↓ 正常发出 172800 个 128-bit DDR 写字后 page_frame_valid = 1
video_out 实际选读页地址的边沿
       ↓ 原子快照 {frame_valid, sync_valid, sync_id, source_frame_id}
34-bit request/ack CDC mailbox → HDMI 像素时钟域
       ↓ left_video_frame_valid / source_frame_id / sync_valid / sync_id
S_video_rd_data（干净 RGB888，hdmi_mixer / 图像效果 / OSD 之前）
       + VTC 控制延迟两拍
       ↓ stereo_left_sampler 在有效源帧首像素锁存 metadata
严格 source_x=8u、source_y=8v → Gray8
       ↓ 14400 个有效样本，并验证完整 1280×720 源光栅
frame_end；任何已检测异常则 frame_abort
```

selector 每个 capture 边界最多消费一个旧请求，一个请求只消费一次。请求与 capture 同周期时：先消费已有 pending 请求，再将新请求入队；队列原本为空时，新请求等下一边界。连续 20/21 分别绑定不同 capture ID。队列满时拒绝新请求并输出 overflow，不覆盖旧请求。

写页开始即撤销该页完整标记。少字、camera FIFO 溢出、错误回写、跨帧旧写突发重叠均不能使该页重新合格。`O_video_out_*` 候选 metadata 现在从实际 `O_video_out_rp` 对应的数组输出；`video_out` 仍在自己的读页选择边沿快照它，不在显示中跟随候选页变化。

像素域在 HDMI VS 起始撤销上一张读帧的 metadata valid；mailbox 到达后采用本张读页快照。首像素时 metadata 不合格则整张显示帧不进入左目流。读页被 camera 重新开始写入、输出 FIFO 溢出或读空会产生 video error，采样器终止正在输出的左目帧。

## 3. 文件清单

下列路径均相对上述 B 工程目录。

新增 RTL：

| 文件 | 用途 |
|---|---|
| `td_project/import/stereo_left_frame_selector.v` | DDR 域请求排队、绑定现有 source ID、selected 统计。 |
| `td_project/import/stereo_left_video_tap.v` | 被动取得并对齐 VTC 首像素、valid、行尾、帧尾。 |
| `td_project/import/stereo_left_sampler.v` | 160×90 Gray8、帧身份锁存、完整性检查、abort/complete 统计、防重放。 |
| `td_project/import/stereo_metadata_mailbox.v` | 复用 A 第 2 阶段已有 mailbox 内容，在 B 使用 16-bit 请求和 34-bit 读页身份两个实例。 |

修改的已有文件恰好四个：

| 文件 | 修改 |
|---|---|
| `user_source/hdl_source/video_in.v` | 在已有四页 metadata 加 sync 标签、写字完成检查、FIFO 溢出观察、selector 接口。原有 capture 计数边界、DDR 地址与数据路径保留。 |
| `user_source/hdl_source/video_out.v` | 实际读页身份到像素域的原子 CDC、读页覆盖与 FIFO 错误观察。原有 RGB 解包及延迟/FPS 统计保留。 |
| `user_source/hdl_source/design_top_wrapper.v` | 接入上述模块，从干净 RGB 分支输出左目流及调试信号。 |
| `td_project/camera_to_dsi_display.al` | 加入四个新 RTL 的工程条目；没有运行工程构建。 |

新增测试和说明：

```text
simulation/stereo_stage3/tb_stereo_left_selector.v
simulation/stereo_stage3/tb_stereo_left_sampler.v
simulation/stereo_stage3/tb_stereo_left_identity.v
simulation/stereo_stage3/tb_stereo_left_vtc.v
simulation/stereo_stage3/tb_stereo_left_page_errors.v
simulation/stereo_stage3/stereo_video_sim_models.v
simulation/stereo_stage3/stereo_video_sim_pattern.vh
simulation/stereo_stage3/run_stereo_stage3.py
doc/stereo_stage3.md
```

`stereo_video_sim_models.v` 里的 FIFO / DDR 数组只用于 testbench，未加入 `.al`，不构成新硬件 Frame RAM。运行目录还保存各项 `.log`、`results.json`、`changes.json` 和 `A_manifest_drift.json`；ModelSim 库也是仿真生成物。

## 4. stereo_left_sampler 接口和时序

所有采样器信号属于 `clk`（顶层 HDMI 像素时钟），`rst` 为同步高有效。参数 `MAX_IDLE_CYCLES=4096`。

| 方向 | 信号 | 含义 |
|---|---|---|
| 输入 | `clk`, `rst` | 时钟、复位。 |
| 输入 | `frame_start_i`, `pixel_valid_i`, `pixel_rgb_i[23:0]` | 已与干净 RGB 对齐的源首像素标记、有效标记和 RGB888。源首像素必须同时有 start 和 valid。 |
| 输入 | `line_end_i`, `frame_end_i` | 行末与最后一个有效源像素同拍。正常源 EOF 为第 720 行行尾；VS 提供异常截断的备用边界。 |
| 输入 | `video_error_i` | 已对齐的 FIFO/读页覆盖等错误。 |
| 输入 | `frame_valid_i`, `source_frame_id_i[15:0]`, `sync_valid_i`, `sync_id_i[15:0]` | 实际读页的完整性及帧身份。 |
| 输出 | `frame_start_o`, `pixel_valid_o`, `gray_o[7:0]` | 所选左目首像素/有效标记/Gray8；首个样本与输出 start 同拍。 |
| 输出 | `x_o[7:0]`, `y_o[6:0]` | 0..159、0..89，只在 valid 时表示样本坐标。 |
| 输出 | `frame_end_o`, `frame_abort_o` | 单拍成功提交/失败终止，互斥；不能用“已收到 14400 点”代替 end。 |
| 输出 | `source_frame_id_o[15:0]`, `sync_valid_o`, `sync_id_o[15:0]` | 接受源首像素时锁存，整张输出及 end/abort 时保持该身份。复位会清零。 |
| 输出 | `left_completed_count_o[31:0]`, `left_abort_count_o[31:0]` | 成功数、已接受左目帧的失败数，复位清零。 |

真实 `video_out` 包含 read-enable 延迟寄存器和 RGB 输出寄存器。因此 `S_hdmi_window_rd_en`、`S_hdmi_user`、`S_hdmi_last` 在 tap 中延迟 **两拍**，然后与 `S_video_rd_data` 一起被采样器读取。Gray 输出再经过采样器 **一拍**寄存器。实际 `uivtc` 的 USER 是首个有效像素标记，LAST 与每行最后有效像素同拍；集成测试使用真实 `uivtc` 验证了这个关系。

```text
对齐的源输入周期：  SOF+valid(x=0)  valid(x=1) ... valid(x=8) ...
下一拍左目输出：    start+valid(0) 无 valid    ... valid(1)   ...
```

仅接收 `frame_valid_i && sync_valid_i` 的完整读页，普通显示帧无左目 start。像素 metadata 中途变化、valid 在行内中断、新 SOF 提前到达、行长度错误、超时、视频错误或截断会 abort，并抑制失败周期的有效样本。

最后一个 Gray 位于源 `(1272,712)`。仍要检查源后续数据直到 `(1279,719)` 的正常 EOF，确认 720 行各 1280 像素且恰好 14400 个样本，才发出 end。因此已经输出 14400 个 Gray、但尾部源行缺失的帧也会 abort。

活动帧收到 reset 的第一拍会产生 abort，持续 reset 不会反复产生 abort；同时统计和身份清零。复位周期的 abort 不保留旧 ID，所有同复位消费者必须直接丢弃未提交图像。普通 abort 保留原帧身份。无 `ready`/反压接口，后续消费者必须接收 valid 脉冲，并在 end 后才能提交帧。

## 5. 采样和 Gray8

```text
u = 0..159, v = 0..89
source_x = 8*u = 0,8,...1272
source_y = 8*v = 0,8,...712
Gray = (77*R + 150*G + 29*B + 128) >> 8
```

只输出 160×90 的 14400 点，不产生上下黑边。未来转换网络坐标时使用 `stereo_y=y_o+15`。

系数用移位加法：77=64+8+4+1，150=128+16+4+2，29=16+8+4+1。各分量先零扩展到 17 bit，再计算加 128，取 `gray_sum[15:8]`。最大和为 `256*255+128=65408`，不溢出。RTL 没有乘法运算；未经综合，未宣称实际 DSP/LUT 使用量。

## 6. 回归结果

ModelSim SE-64 2020.4。新增及受影响模块的独立编译：**0 errors / 0 warnings**。下面七项行为测试均 PASS，仿真也均 0 errors / 0 warnings。

| testbench | 结果和覆盖 |
|---|---|
| `tb_stereo_left_selector` | PASS：普通帧、连续 20/21、空队列/已有 pending 时请求与 SOF 同拍、4 项溢出、复位、ID 回绕。 |
| `tb_stereo_left_sampler` | PASS：完整 720p、全部 14400 点的位置及 Gray；边界颜色与舍入；普通帧、连续和非连续旧页重放；15 种 abort 场景与恢复；14399 截断、额外样本不会生成 14401、尾部缺行、sync 回绕。 |
| `tb_stereo_left_identity` | PASS：真实修改后的 video_in/out、两个 CDC、tap、sampler 加行为 FIFO/DDR；按默认每帧 172800 个写字写三张完整页。sync `0012` 对应 source `1234`；20/21 对应 `1235/1236`。三次输出各 14400 点，逐像素检查 RGB 与 Gray。读帧中切换实时候选页不改变当前身份；100-word 未完成页不能输出。 |
| `tb_stereo_left_vtc` | PASS：真实 uivtc（H=1280/1650，V=720/750）、video_out、tap、sampler；检查全部 921600 个源 RGB、行尾、14400 Gray；下一张帧读页遭覆盖产生 abort，不产生第二个成功 end。 |
| `tb_stereo_left_page_errors` | PASS：真实 video_in，小参数故障测试；完整/少字、FIFO 溢出、跨 SOF 旧写突发、MIPI 错误回写、ID 不重复增加、复位。 |
| 既有 `tb_stereo_sync_gen` | PASS：以缩短周期参数检查 period=20、width=4、复位及回绕；顶层仍为原有约 5 Hz 配置。 |
| 既有 `tb_stereo_udp` | PASS：读取 A TX 和 B RX 源码的 v2 UDP 回归；未修改 A。 |

`1234` 是测试通过层级赋值预置既有计数器起点所得，硬件 reset 初值仍为 0。测试图用基于 `(x,y,source_id)` 的 RGB 编码，不只检查几个角点。

静态命名端口检查：7 个受影响实例 PASS。B 当前 101 个活动 Verilog 源文件与修改前备份 97 个文件都只有原有 DDR 错误：

```text
ph1p35_324_ddr_wrapper.v(61): Undefined variable: 'dhi_clk'
```

两者都有相同 80 条 HDMI 加密 IP 的 `(vlog-2600)` 声明语法警告，没有新增类型的全源码警告。这是全活动 Verilog 源的 vlog 静态编译，不能宣称整个 FPGA 工程编译/综合通过。原 DDR wrapper 字节未改。

复跑行为测试和当前 B 静态检查：

```powershell
python C:\Users\lx292\Desktop\test\lab_ex3_osd_SC500_720P\lab_ex3_osd\simulation\stereo_stage3\run_stereo_stage3.py
```

本次还用修改前备份检查范围并复现旧错误：

```powershell
python C:\Users\lx292\Desktop\test\lab_ex3_osd_SC500_720P\lab_ex3_osd\simulation\stereo_stage3\run_stereo_stage3.py --baseline C:\Users\lx292\AppData\Local\Temp\stereo_stage3_bdgnx8tz --allow-board-a-manifest-drift
```

该额外参数只容许记录 **A 清单一项**的变化，不能容许 A HDL 变化，也不会把 A 范围检查写成 PASS；见第 9 节。备份补充了原先未拷贝的 30 个未改辅助源，以便复现全源码编译；四个修改前 B 文件的备份没有被覆盖。

## 7. sync_id 是否准确对应 source_frame_id

对于成功跨 CDC、进入 selector 队列的请求，绑定规则是确定的：每次正常 capture 最多绑定一个 pending 请求，使用当拍既有 capture counter 的下一值，标签跟同一写页与实际读页传播。成功左目 end 对应的 `sync_id + source_frame_id` 从选择到输出保持一致；仿真验证了 `0012→1234` 和 `20/21→1235/1236`。

**不能保证每个发生器请求都有一张成功输出的左目图。** CDC/队列溢出可丢请求，写页不完整会不合格，已选页也可能未显示便被覆盖，或采样中发生 abort。不会以旧帧代替失败帧。selected 是绑定数量，completed 是实际成功提交数量，abort 只统计已经进入采样器的失败帧；从未进入采样器的坏页不会增加 abort。

同一已标记 DDR 页可能重复显示。采样器使用 16-bit sync 序号的新旧判断抑制重复和更旧页面，forward distance 必须为 1..32767，支持 FFFF→0000。一次接受即记录 ID，即使其后 abort，也不自动重试这个 ID。

## 8. 调试和所有已知边界

顶层保留轻量 `keep` 信号：`left_selected_count`（DDR 域）、`left_completed_count` / `left_abort_count`（像素域）、`last_left_sync_id` / `last_left_source_frame_id`（最后接受帧的锁存身份）、selection/输出 valid/end/abort、请求 mailbox overflow、selector overflow。没有增加 OSD。这些 last ID 不是“最后成功帧 ID”；普通 abort 后仍是失败帧身份，reset 后为 0。未来用系统域调试总线读取统计时须做 CDC。

已知限制：

1. B 的“下一帧”指请求经过 CDC 后遇到的下一 RAW 派生 DDR capture 边界。不是直接 CSI SOF，更不是摄像头硬件曝光同步；CDC 边沿附近的请求可能落到再下一帧。A 的选择边界在 CSI，两个自由运行传感器的曝光同步未验证。
2. B source ID 是 B 本地原有计数，与 A 的 source ID 不必相同。sync ID 才是共享请求序号。独立复位会改变序号纪元，目前没有跨板纪元握手。
3. 4 项请求队列和单项 CDC mailbox 都有限，异常请求频率、停钟、不同步复位可能丢请求。默认 5 Hz 正常时钟下余量很大，但没有重传机制，也未验证独立停钟/恢复后的 stale metadata。
4. “下一完整帧”采用先绑定下一 capture、再验证该写页的策略；若这帧不完整，该请求失败，不自动转绑定到更晚帧。
5. 沿用现有 DDR 页轮转和读写调度；不是所有选中页都会在被覆写前读出。覆盖检测会 abort 已在读取的左目帧。display metadata 未及时到达首像素也会跳过帧。
6. serial-number 防重假设新 ID 的前进差小于 32768。丢失/跳跃达到半个序号空间或改变纪元后，需要 reset/resync。没有重放历史表；abort 后不自动重试旧页。
7. 采样接口没有反压；未来 Frame RAM 消费者应接收所有 valid，并只在 end 后提交，abort 时丢弃已收样本。普通 metadata 在 end/abort 后继续保持，数据有效性由控制脉冲限定。
8. 几何固定 1280×720，每行内 valid 连续，line_end 必须与最后有效像素同拍。行间可 blank，默认超时 4096 拍适配当前 370 拍水平空白。改变分辨率/VTC/FIFO 时序必须重新适配。
9. 页完成依据现有接口发出的 DDR 写字数量、溢出和边界重叠观察，不是独立的 DDR 存储回读校验或完整 CSI CRC/行检查。顶层 `I_mipi_rx_error` 仍接 0；保持数量的像素错误、ISP 内部错误和多余源数据不能全部检出。
10. 行为 FIFO 使用注册读输出合同，DDR 使用行为延迟。未模拟厂商 IP/PHY 的全部细节，未验证板级信号完整性、STA、资源占用或实际上板表现。
11. A 第 2 阶段的异常积压请求策略与 B 的四项队列不同；本阶段未做跨板 pairing，也未验证异常积压下左右是否都得到同一个 sync ID。
12. 原有 `dhi_clk` 全源码编译错误及 HDMI IP 警告仍存在，本阶段按要求保留。

## 9. 范围审计发现：A 工程清单变化

B 基线比较确认：只有上述四个旧文件发生修改，只有四个新 RTL 加入工程；已有约束、DDR wrapper、UDP、OSD、运动处理及小车模块保持原字节。

A HDL 与本阶段初始 SHA256 相同，但 **A `td_project/camera_to_dsi_display.al` 在检查期间与初始哈希不同**。当前清单文本与第 2 阶段之前备份一致，缺少下列第 2 阶段新增条目：

```text
stereo_sync_rx.v
stereo_frame_selector.v
stereo_page_metadata.v
stereo_metadata_mailbox.v
stereo_metadata_fifo.v
```

文件修改时间为 2026-10-02 16:59:06（本机时间）。初始 SHA256 为 `d3695b1e772925f8c5493f0478662edcfbc58c437681b3b0d098e0dc2534419f`，观察到的为 `bdab56223eab9329897d429007290277c80233b0e96f9843565ec3391167e70d`。变化来源不能从文件证据确定。第 3 阶段只读取 A，未写入或恢复其清单。

该差异使 A 当前工程条目不能直接代表第 2 阶段已验证配置，不能宣称 A 整个工程未变化。`results.json` 将范围总体状态保留为 `REVIEW_REQUIRED`、A HDL 为 `UNCHANGED`、B 范围为 `PASS`；详见 `A_manifest_drift.json`。UDP 回归直接使用 A TX/B RX 文件，PASS 不等于当前 A 清单完整。

第 3 阶段到此停止。
