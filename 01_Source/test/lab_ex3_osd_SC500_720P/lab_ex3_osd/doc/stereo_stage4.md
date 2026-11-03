# 双目第 4 阶段：B Ethernet 右目 Gray8 准备

日期：2026-10-02。实施对象：`C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd`。

右目模块已接入现有 RX，输出 160×90 Gray8、锁存的帧身份及转换后的 bbox。三个新 testbench、七个第 2 阶段 testbench 和五个独立左目 testbench 共 15 项全部 PASS。没有新增硬件 Frame RAM，没有实现左右目配对、SAD、视差、距离、测距显示或小车控制。没有运行 FPGA 综合、布线或下载。

## 1. 新增/修改文件和范围

新增 RTL：

- `td_project/import/stereo_right_capture.v`

新增测试和复跑工具：

- `simulation/stereo_stage4/tb_stereo_right_capture.v`
- `simulation/stereo_stage4/tb_stereo_gray_equivalence.v`
- `simulation/stereo_stage4/tb_stereo_right_udp.v`
- `simulation/stereo_stage4/stereo_right_sim_pattern.vh`
- `simulation/stereo_stage4/run_stereo_stage4.py`

新增说明：`doc/stereo_stage4.md`。仿真目录还保存日志、ModelSim 库、源列表、`results.json`、`changes.json`、`audit_before.json`、两个旧文件的 `.before.txt` 证据及 `verified_source_hashes.json`。

修改已有设计文件恰好两个：

| 文件 | 修改 |
|---|---|
| `user_source/hdl_source/design_top_wrapper.v` | 新增 RIGHT 输出/debug wires、模块实例和现有 RX 的接线；增加变更注释。 |
| `td_project/camera_to_dsi_display.al` | 注册 `import/stereo_right_capture.v`，Syn/P&R 启用、属于 design_1，未排除。 |

去除新增注释/声明/实例及 source entry 后，两个旧文件都与开始时备份逐字节一致。A 的 HDL、清单、约束、testbench 和回归脚本哈希未变；B 的 UDP parser、RX wrapper、左目代码、同步发生器、约束、HDMI/DDR 和小车代码均未变。历史回归脚本只被读取，新回归的所有输出写到 B 本阶段目录，没有覆写 A 或第 2/3 阶段的日志。

`tb_stereo_gray_equivalence` 的 Gray 比较数组仅属于 simulation，未注册到 FPGA 工程。新 RTL 没有图像数组或像素 FIFO。

## 2. 顶层 RIGHT 链路

```text
原有 RGMII / Ethernet / UDP stack
  → 原有 video_udp_rx v2
      包序列、版本、长度、metadata 一致性校验
      RGB token + START/END/ABORT + metadata 已跨到 S_hdmi_pixel_clk
  → S_eth_rx_*（干净 160×120 RGB888 + UDP v2 bbox）
  → stereo_right_capture @ S_hdmi_pixel_clk，rst=~S_hdmi_rst_n
      START 原子锁存身份与 bbox
      只在 valid 时推进 160×120 坐标
      裁掉 y=0..14 和 y=105..119
      17-bit shift-add Gray8
      检查 19200 个源像素、14400 个 Gray 和 END
  → right_frame_start / right_pixel_valid / right_gray / right_x / right_y
      right_frame_end / right_frame_abort
      right_udp_frame_id / right_sync_valid / right_sync_id / right_source_frame_id
      right_bbox_current_valid / right_bbox_valid / cropped coordinates / result identity
```

没有新增 CDC，因为 RGB、帧控制和 metadata 已在同一像素域。RIGHT 为新增分支，原有 Ethernet framebuffer/HDMI 分支保持原样。LEFT 和 RIGHT 均为 160×90 Gray8，但没有连接配对逻辑，也没有比较左右 source ID 或 sync ID。

## 3. 完整接口

模块：`stereo_right_capture`。参数：`RIGHT_FRAME_TIMEOUT_CYCLES=15000000`，最小合法值为 2，单位是 `clk` 周期。同步高有效 `rst`。共 46 个端口：

```verilog
input  wire        clk;
input  wire        rst;
input  wire        frame_start_i;
input  wire        pixel_valid_i;
input  wire [23:0] pixel_rgb_i;
input  wire        frame_end_i;
input  wire        frame_abort_i;
input  wire [15:0] udp_frame_id_i;
input  wire        sync_valid_i;
input  wire [15:0] sync_id_i;
input  wire [15:0] source_frame_id_i;
input  wire        bbox_valid_i;
input  wire [7:0]  bbox_x1_i;
input  wire [6:0]  bbox_y1_i;
input  wire [7:0]  bbox_x2_i;
input  wire [6:0]  bbox_y2_i;
input  wire        bbox_source_valid_i;
input  wire [15:0] bbox_source_frame_id_i;
input  wire [15:0] bbox_result_id_i;

output wire        frame_start_o;
output wire        pixel_valid_o;
output wire [7:0]  gray_o;
output wire [7:0]  x_o;
output wire [6:0]  y_o;
output wire        frame_end_o;
output wire        frame_abort_o;
output wire [15:0] udp_frame_id_o;
output wire        sync_valid_o;
output wire [15:0] sync_id_o;
output wire [15:0] source_frame_id_o;
output wire        bbox_current_valid_o;
output wire        bbox_valid_o;
output wire [7:0]  bbox_x1_o;
output wire [6:0]  bbox_y1_o;
output wire [7:0]  bbox_x2_o;
output wire [6:0]  bbox_y2_o;
output wire        bbox_source_valid_o;
output wire [15:0] bbox_source_frame_id_o;
output wire [15:0] bbox_result_id_o;
output wire [31:0] right_completed_count_o;
output wire [31:0] right_abort_count_o;
output wire [31:0] right_timeout_count_o;
output wire [31:0] right_bbox_valid_count_o;
output wire [31:0] right_bbox_stale_count_o;
output wire [15:0] last_right_sync_id_o;
output wire [15:0] last_right_source_frame_id_o;
```

START/valid/end/abort/Gray/坐标都使用输出寄存器。没有 ready/反压。

## 4. 坐标和 Gray

完整输入为 19200 个按行排列的像素。`eth_x` 从 0 到 159，行末回 0；`eth_y` 从 0 到 119。**只有输入 pixel_valid 才推进坐标**，包间空隙不改变坐标。

| 输入 | 输出 |
|---|---|
| `(0,15)` | `(0,0)` |
| `(159,15)` | `(159,0)` |
| `(0,104)` | `(0,89)` |
| `(159,104)` | `(159,89)` |
| y=0..14、105..119 | 不产生 pixel_valid_o |

有效区输出 `x_o=eth_x`、`y_o=eth_y-15`，14400 点。没有缩放、平均或新的采样相位：A 已按 `(8u,8v)` 形成有效图，B 这里只取出这幅有效图。

```text
Gray = (77*R + 150*G + 29*B + 128) >> 8
77  = 64+8+4+1
150 = 128+16+4+2
29  = 16+8+4+1
```

右目使用与未修改的 `stereo_left_sampler` 相同的 17-bit shift-add 表达式，取和的 `[15:8]`。最大和 `256*255+128=65408`，不溢出。没有乘法器实例；未综合，不能宣称实际 DSP/LUT 使用量。

## 5. metadata 原子锁存和帧控制

START 在 idle 状态被接受时，12 个 metadata 字段一起保存到一个 113-bit 寄存器，包括原始 bbox 坐标及 bbox source/result 身份。整帧输出只使用这个寄存器，帧中外部 metadata 即使全部改变也不重标记当前帧。END/ABORT 后继续保持最后身份，直到下一次被接受的 START 或 reset。

`frame_start_o` 在接受 Ethernet START 后经过一个寄存器级输出，此时还没有有效区 Gray；首个 Gray 要等前 2400 个上黑边像素经过。这一点与左目首个 Gray 同拍 START 的行为不同，但两者都提供带 START/END/ABORT 的帧流，坐标定义相同。Gray 和 valid 也经过同一个输出寄存器级，不额外改变像素次序。

完整 END 必须同时满足：已经有合法 START，收到恰好 19200 个源像素，遍历完 120 行，输出恰好 14400 个有效区样本，并收到输入 END。正常 END 可在末像素之后，也可与末像素同拍。最后一个 Gray 在源 `(159,104)`，还要接收底部 15 行才允许 END。

输入 ABORT、短帧/多像素/非法坐标状态、过早 END、新 START 覆盖活动帧、START 时非法 bbox 坐标或顺序、reset、idle timeout 均终止本帧，不能产生成功 END。输入 ABORT 优先于 END，失败周期不输出有效像素。新 START 覆盖活动帧时，只 abort 旧帧，保留旧身份，不同时接受新帧；随后等待下一 START。正常 RX 自己在新 START 前发旧 ABORT，集成回归已验证可恢复。

没有活动帧时忽略孤立/超时后的迟到 PIXEL、END、ABORT，必须等下一 START 才恢复，避免重复计数或把旧尾部当新图。活动帧 reset 的首拍发一次 abort，持续 reset 不反复发；同时清零身份、统计和状态。reset 周期不保留旧 ID，同 reset 消费者必须丢弃所有未提交数据。

## 6. bbox current/stale 与坐标转换

```text
bbox_current_valid = latched_bbox_valid
                  && latched_bbox_source_valid
                  && latched_bbox_source_frame_id == latched_source_frame_id
```

比较只在右目自身的图像和 bbox 身份之间进行，没有比较 A/B 本地 source ID。不同 source ID、缺少 bbox source valid 或没有检测框，都不会使完整右目图无效。

随后先求 bbox 与 `[0..159] × [15..104]` 的**含边界交集**，再 clip、减 15，并验证 x1≤x2、y1≤y2。`bbox_valid_o` 表示“当前帧且与有效区有交集”；`bbox_current_valid_o` 只表示原始 bbox 的帧归属。当前框完全处于黑边时可以 current=1、valid=0。无效 bbox 输出坐标为零。

| 原始 bbox / 归属 | 转换结果 |
|---|---|
| 当前 `(40,30)-(90,80)` | valid=1，`(40,15)-(90,65)` |
| 当前 `(20,5)-(80,30)` | valid=1，`(20,0)-(80,15)` |
| 当前 `(40,100)-(90,115)` | valid=1，`(40,85)-(90,89)` |
| 完全位于上/下黑边 | valid=0，图像仍可正常 END |
| stale bbox / 缺少 bbox source valid | current=0、valid=0，图像仍可正常 END |

直接使用 UDP v2 metadata，没有 `FF2020` 扫描。单元测试把 padding 设为红色，并在有效图内放入真实 `FF2020` 像素，输出 bbox 仍只由 metadata 决定。

START 的范围检查与当前网络光栅一致：声明有效的 bbox 必须 x2≤159、y2≤119，且端点顺序合法，否则是 malformed metadata，整帧拒绝；不会把越界垃圾当合法框。bbox source 无效/过期属于归属失效，不属于这种语法错误。原 RX 保留原有网络 metadata 校验；帧中网络 metadata 不一致仍由 RX 发 ABORT，本模块不重解析包。

## 7. timeout 与统计

默认 `RIGHT_FRAME_TIMEOUT_CYCLES=15000000`，顶层显式使用同值。时间为 `15000000 / pixel_clock_hz` 秒，应按板上允许的最大接收停顿调整。

进入活动帧后，每个有效源像素（包括 padding）使 idle 计数清零。START 不计入 idle；若连续 N 拍没有像素进展、END 或 ABORT，则在第 N 拍输出 abort、timeout_count 加一，随后等待新 START。同拍的像素进展、END 或 ABORT 优先于 timeout。这是 **无进展 timeout**，不是整帧总时间上限。

| 统计 | 定义 |
|---|---|
| completed | 成功 END 数 |
| abort | 拒绝/终止数，包括 malformed START 与 timeout；reset 将统计清零 |
| timeout | abort 中由无进展 timeout 引发的数量 |
| bbox_valid_count | 成功帧中 bbox_valid_o=1 的数量 |
| bbox_stale_count | 成功帧中原始 bbox_valid=1、但 bbox 不属于当前图像（含缺少 source valid）的数量 |
| last sync/source | 最后接受 START 的身份，也可能属于失败帧；不是最后成功帧身份 |

统计为 32-bit 自然回绕；身份为 16-bit。所有 RIGHT 输出/debug 信号属于像素域，顶层添加了轻量 keep wires，没有增加 OSD。

## 8. 所有 testbench 结果

ModelSim SE-64 2020.4，三个独立库避免历史仿真模型相互覆盖。所有行为测试和核心编译均 0 errors / 0 warnings。

| Testbench | 结果及覆盖 |
|---|---|
| `tb_stereo_right_capture` | PASS：19 个完整帧、15 类拒绝场景；全像素坐标/Gray/padding、四角、14399 截断、不会产生 14401、全部 metadata 帧中修改仍保持、current/stale/黑边 bbox、连续 sync20/21/22、input abort、覆盖 START、非法 bbox、reset、timeout、末像素 END、START 与首像素同拍及恢复。 |
| `tb_stereo_gray_equivalence` | PASS：使用原 tb_stereo_left_sampler 相同 RGB pattern，真实未修改 LEFT 与真实 RIGHT 逐点比较全部 14400 Gray；另用整数公式校验 LEFT。包括黑白、RGB 主色、舍入。left source153/right source81 均允许，不进行 pairing。 |
| `tb_stereo_right_udp` | PASS：真实 v2 RX→RIGHT；四个完整帧每幅 14400 点；丢尾包已输出 14400 仍 timeout abort；网络 metadata 变化由 RX abort；后续完整帧恢复、stale bbox 图像成功。 |
| `tb_stereo_sync_gen` | PASS |
| `tb_stereo_sync_selector` | PASS |
| `tb_stereo_udp` | PASS |
| `tb_stereo_identity` | PASS |
| `tb_stereo_bbox` | PASS |
| `tb_video_udp_tx` | PASS |
| `tb_npu_bbox_threshold` | PASS |
| `tb_stereo_left_selector` | PASS |
| `tb_stereo_left_sampler` | PASS |
| `tb_stereo_left_identity` | PASS |
| `tb_stereo_left_vtc` | PASS |
| `tb_stereo_left_page_errors` | PASS |

第 3 阶段的 UDP/同步发生器回归与第 2 阶段使用相同 testbench，本次运行一次覆盖共享项，共 15 个不同 testbench。最后补充的右目 14399/同拍 START 用例重新独立编译和仿真，日志为 `unit_final_compile.log` 和 `stage4_work_tb_stereo_right_capture.log`。

静态检查：新模块 46 个端口完整接线，RX 时钟/复位/所有输入对应实际 S_eth_rx 信号，工程 entry 活动且唯一，无新增硬件图像数组、无颜色扫描。Verilog-2005、完整组合默认、单驱动、同步 reset、17-bit 算术及单时钟结构检查通过；没有 AXI 接口。

A 全部 108 个活动 Verilog 静态编译：0 error / 80 条原有 HDMI IP 警告。B 全部 102 个活动 Verilog 静态编译：原有 `ph1p35_324_ddr_wrapper.v(61)` 的 `dhi_clk` 未声明错误，加相同 80 条 HDMI IP 警告。wrapper 字节未改，不能宣称 B 全工程编译/综合通过。

## 9. 复现与日志来源

重新执行全部仿真和静态检查：

```powershell
python C:\Users\lx292\Desktop\test\lab_ex3_osd_SC500_720P\lab_ex3_osd\simulation\stereo_stage4\run_stereo_stage4.py
```

本次先实际运行全部 15 项，再仅恢复新增上下文行的旧换行格式，最终补充单元边界用例。没有改变 RTL token。收尾使用 `--reuse-passing-logs` 重新校验日志与范围；该模式要求所有 RTL/testbench 的规范化换行哈希及文件集合一致，不重新仿真，也不把日志写成一次新的仿真。`results.json.execution_mode` 明确记录来源。默认不加该参数时，会重新运行 ModelSim。

## 10. 已知限制

1. 输出是流，END 之前可能已经发出部分或全部 14400 样本；未来消费者必须在 END 后提交、ABORT 时丢弃，没有新增图像暂存 RAM。
2. 没有 ready/反压，消费者必须接收每个 valid。START 早于第一个 Gray，metadata/bbox 在 END 后仍保持，必须用控制脉冲限定有效帧。
3. 几何固定为 160×120 裁到 160×90。没有外部 x/y/行标记，只能按 token 数量追踪光栅，无法独立识别数量保持一致的像素替换、错误顺序或内容损坏；网络包序列校验仍依赖原 RX。
4. timeout 仅监测无进展；持续慢速像素会不断重置计数，没有整帧最大年龄限制。默认值须结合板上链路停顿调整；没有进行实时网络/板级测量。
5. capture 超时只清自己的状态，不复位或改写 RX。迟到数据忽略至下一 START；真实 RX 新首包时发旧 ABORT 的恢复路径已测，没有增加 UDP 重传、重排序或额外协议。
6. 帧中外部 metadata 更新被忽略，属于明确的锁存行为；网络 metadata 错误由原 RX 转成 ABORT。START 时非法有效 bbox 坐标会拒绝帧，stale/缺少 bbox source valid 不会拒绝图像。
7. sync_valid=0 的完整网络帧也可输出，原 flag 保留为 0。没有按 sync ID 去重；A 重复显示同一源页时可以重复输出。这些筛选/配对属于后续阶段，本阶段没有实现。
8. source ID 只在右目内用于 bbox 归属，不与左目 source ID 比较。未来配对依据有效 sync ID；16-bit 回绕、独立复位 epoch 和 GPIO 丢脉冲的限制仍存在，没有 epoch 恢复握手。
9. reset 清空当前身份与统计；reset abort 不保留旧身份。跨域 debug 读取 RIGHT 统计/ID 时需要 CDC，当前不提供系统域读接口。
10. 仿真使用现有行为模型与 UDP 字节输入，未模拟实际传感器、RGMII PHY 全链路或真实 NPU 推理。没有 STA、资源统计或硬件下载验证；B 原有编译错误按要求保留。

本阶段到此停止。
