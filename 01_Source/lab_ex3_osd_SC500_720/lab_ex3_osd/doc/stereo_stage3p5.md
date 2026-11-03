# 第 3.5 阶段：A 工程清单恢复

日期：2026-10-02。状态：恢复完成，七项原有回归全部 PASS，A 清单 drift 已 RESOLVED。

唯一设计文件修改是 A 的 `td_project/camera_to_dsi_display.al`：恢复五个缺失 source entry。没有修改任何 HDL、GPIO/时序约束、testbench 或原有回归脚本；没有开发新双目功能，没有综合、布线或下载。B 的设计文件也未修改。另保存了本阶段报告、仿真日志与审计结果，并更新了第 3 阶段的审计状态。

## 文件证据与原因

对照 `doc/stereo_stage2.md`、`sim/stereo_stage2/changes.json`、第 2 阶段源列表、当前源码及第 3 阶段开始时 SHA256 快照：A 受保护的 HDL/约束文件保持一致，只有 `.al` 不同。修复前清单文本与第 2 阶段修改前备份一致，缺少五个新增模块块。能确认具体差异，不能确定导致变化的人员、程序或命令。

只插入五个块后，整个 `.al` 恢复到第 2 阶段结束/第 3 阶段开始快照的**精确字节哈希**：

```text
修复前：bdab56223eab9329897d429007290277c80233b0e96f9843565ec3391167e70d
修复后：d3695b1e772925f8c5493f0478662edcfbc58c437681b3b0d098e0dc2534419f
```

沿用历史条目的换行和属性格式；去掉本次插入的五个块后，剩余字节与修复前完全一致。旧条目、项目参数、约束条目均未重写。

## 第 2 阶段 A 文件及注册检查

以下路径相对 `C:/Users/lx292/Desktop/lab_ex3_osd_SC500_720/lab_ex3_osd`。

| 第 2 阶段动作 | RTL 文件 | 当前工程条目 |
|---|---|---|
| 新增 | `td_project/import/stereo_sync_rx.v` | 本次恢复 `import/stereo_sync_rx.v` |
| 新增 | `td_project/import/stereo_frame_selector.v` | 本次恢复 `import/stereo_frame_selector.v` |
| 新增 | `td_project/import/stereo_page_metadata.v` | 本次恢复 `import/stereo_page_metadata.v` |
| 新增 | `td_project/import/stereo_metadata_mailbox.v` | 本次恢复 `import/stereo_metadata_mailbox.v` |
| 新增 | `td_project/import/stereo_metadata_fifo.v` | 本次恢复 `import/stereo_metadata_fifo.v` |
| 修改 | `user_source/hdl_source/design_top_wrapper.v` | 原条目完整，未改 |
| 修改 | `user_source/hdl_source/video_in.v` | 原条目完整，未改 |
| 修改 | `user_source/hdl_source/video_out.v` | 原条目完整，未改 |
| 修改 | `td_project/import/video_udp_tx.v` | 原条目完整，未改 |
| 修改 | `td_project/import/ethernet_video_tx_top.v` | 原条目完整，未改 |
| 修改 | `td_project/import/npu_bbox_overlay_160x120.v` | 原条目完整，未改 |
| 修改 | `td_project/import/npu_video_input.v` | 原条目完整，未改 |
| 修改 | `td_project/import/npu_rgb_input.v` | 原条目完整，未改 |

恢复的五个条目位于 `<Verilog>` 区，属性与第 2 阶段一致：`UsedInSyn=true`、`UsedInP&R=true`、`BelongTo=design_1`，没有 `AutoExcluded=true`。其余八个修改后的 RTL 同样为活动 design source，路径存在、无重复。

| 第 2 阶段修改的约束/清单 | 当前状态 |
|---|---|
| `user_source/constraints_source/pin.adc` | `../user_source/constraints_source/pin.adc` 仍注册到 `constraint_1`，Syn/P&R 均启用。`stereo_sync_i` 仍为 V1、LVCMOS33、PULLDOWN，V1 唯一分配，文件未改。 |
| `td_project/camera_to_dsi_display.sdc` | `camera_to_dsi_display.sdc` 仍注册到 `constraint_1`，Syn/P&R 均启用。GPIO 到 `u_stereo_sync_rx/input_sync_reg[0]` 的 false path 仍在，实例与寄存器名对应，文件未改。 |
| `td_project/camera_to_dsi_display.al` | 本次仅恢复五个 source 块。其余 RTL、SystemVerilog、ADC、SDC、IP 等活动路径存在且无重复。 |

这些是约束的文件注册与名称一致性检查，没有执行 STA 或引脚硬件验证。

## 顶层依赖仍在

五个模块并非全都直接实例化在顶层；直接和间接依赖分别为：

```text
design_top_wrapper
  ├─ stereo_sync_rx             u_stereo_sync_rx
  ├─ stereo_frame_selector      u_stereo_frame_selector
  ├─ video_in                   u_video_in
  │    └─ stereo_page_metadata
  ├─ video_out                  u_video_out
  │    └─ stereo_metadata_mailbox
  └─ ethernet_video_tx_top      u_ethernet_video_tx_top
       └─ video_udp_tx
            └─ stereo_metadata_fifo
```

两个 `npu_video_input`、其内部 `npu_rgb_input` 和 bbox overlay 也保留原有引用。UDP v2 与 RAW 像素接线、NPU/MIPI/DDR/HDMI 实现没有修改。

## Testbench 注册与回归

沿用第 2 阶段方案：testbench 注册在原有 `sim/stereo_stage2/run_stereo_stage2.py` 的编译/运行列表，**不加入 FPGA 的综合 source list**。未修改脚本或任何 testbench。

| Testbench | 原有文件位置 | 本次结果 |
|---|---|---|
| `tb_stereo_sync_gen` | B `sim/tb_stereo_sync_gen.v` | PASS |
| `tb_stereo_sync_selector` | A `sim/stereo_stage2/tb_stereo_sync_selector.v` | PASS |
| `tb_stereo_udp` | A `sim/stereo_stage2/tb_stereo_udp.v` | PASS |
| `tb_stereo_identity` | A `sim/stereo_stage2/tb_stereo_identity.v` | PASS |
| `tb_stereo_bbox` | A `sim/stereo_stage2/tb_stereo_bbox.v` | PASS |
| `tb_video_udp_tx` | A `sim/tb_video_udp_tx.v` | PASS |
| `tb_npu_bbox_threshold` | A `sim/tb_npu_bbox_threshold.v` | PASS |

实际执行原脚本：

```powershell
python C:\Users\lx292\Desktop\lab_ex3_osd_SC500_720\lab_ex3_osd\sim\stereo_stage2\run_stereo_stage2.py
```

核心编译和七项行为仿真均 0 errors / 0 warnings。A 命名端口及 V1 检查 PASS，覆盖 13 个实例。A 恢复为 108 个活动 Verilog 源，全源码 vlog 静态编译 0 errors / 80 条原有 HDMI IP 位宽警告。B 当前 101 个活动 Verilog 源仍有原有 `dhi_clk` 错误和相同 80 条 HDMI IP 警告，没有修改该错误。

回归沿用原有模型和测试范围，不代表真实摄像头、DDR PHY、NPU 推理或实际上板已验证。B 第 3 阶段行为测试没有在本次重新运行；B 工程文件未改。

## 审计关闭与产物

开始前记录 A/B 共 712 个 HDL、约束、项目、IP 配置、testbench 和脚本文件哈希。本阶段结束比较：A 只有 `.al` 变化，B 无变化；没有新增或删除受保护文件。A 的全部第 3 阶段初始快照哈希现在也完全相符。

产物集中在 A `sim/stereo_stage3p5/`：

- `audit_before.json`：本阶段开始时的 A/B 受保护文件哈希。
- `A_manifest_before.al.txt`：修复前清单证据。
- `prior_stage2_artifacts/`：运行前已有的第 2 阶段日志、结果和源列表备份。
- 各 testbench `.log`、`compile_core.log`、`A_syntax.log`、`B_syntax.log`、源列表和 `results.json`：本次原脚本回归结果的副本。
- `audit_results.json`：source 注册、约束、实例依赖、testbench 路径、哈希及当前审计结果。

B `simulation/stereo_stage3/A_manifest_drift.json` 已从 `REVIEW_REQUIRED` 更新为 `RESOLVED`，保留修复前证据和原状态，记录本次恢复哈希及七项 PASS。B 第 3 阶段 `results.json` 的当前范围状态改为 PASS，原始范围观察另行保留，行为测试结果仍属于原第 3 阶段运行。

**没有剩余的清单 drift REVIEW_REQUIRED 项。** 变化来源仍无法确定，作为已记录的证据边界保留；B 原有编译错误仍为已知 pre-existing 问题。

第 3.5 阶段到此停止。
