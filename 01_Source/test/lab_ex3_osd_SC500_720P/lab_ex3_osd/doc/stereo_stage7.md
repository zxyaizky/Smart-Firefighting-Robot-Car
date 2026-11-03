# B HDMI 双目调试叠加（Stage 7）

日期：2026-10-02。B 路径：`C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd`。

已完成最新结果叠加、7 项行为仿真、限定修改审计，以及原生综合/布局/布线构建。
构建状态：**COMPLETE**。布线后时序：**未收敛**。
未连接硬件、未下载、未声称实际下板通过。

## 显示路径及接入点

确认现有本地链路为 SC500 原厂 1280×720 LEFT camera → ISP/DDR/video_out →
hdmi_mixer → mode_select → video_logo_overlay → HDMI TX。
`mode_select` 默认模式 0 是原有本地彩色画面，保留已有按键切换算法模式。
`S_logo_in_rgb=data`，没有切到 `S_network_hdmi_rgb`；原网络 framebuffer 未改。

新增 overlay 位于 logo 后、TX 前：输入 `S_logo_out_data`，输出 `stereo_hdmi_rgb`。
HDMI TX 的 VS/DE 仍直接使用 `S_logo_out_vsync` / `S_logo_out_de`；只改 RGB 连接。
由同一组最终 VS/DE 生成 `stereo_pixel_x_reg[10:0]` / `stereo_pixel_y_reg[9:0]`，
范围 0..1279 / 0..719。overlay 的 RGB 为组合输出，**新增像素延迟=0**。
没有修改 VTC、PLL、同步信号、video_out、DDR、ISP 或 Frame RAM。

## 结果语义和接口推导

测距、pair_ctrl、Gray RAM、overlay 全部使用 `S_hdmi_pixel_clk`（现有约 75 MHz）。
因此无需新 CDC/mailbox，严禁将此同域模块直接用于异步时钟。

`stereo_hdmi_result_latch`：clk/rst、pair_take、pair_sync_id、RIGHT bbox、
range_done、range_valid、disparity[5:0]、distance_mm[15:0]、range_sync_id →
latest bbox/range/disparity/distance/pair_sync_id。坐标 x 为 8 位、y 为 7 位。
`pair_valid && pair_accept` 时保存 bbox 和 pair ID，`range_done` 时以一组 70 位
寄存器发布完整结果；新计算期间保持上一结果。ID 不匹配时抑制 bbox/range valid。
下一次完整 invalid 结果替换先前 valid 结果，不继续画旧框。

`stereo_hdmi_overlay`：clk/rst、pixel_x[10:0]、pixel_y[9:0]、DE、rgb[23:0]、
latest RIGHT bbox、range_valid、disparity[5:0]、distance_mm[15:0] → rgb[23:0]。
参数 `BOX_THICKNESS=3`，`BOX_COLOR=24'h00ff00`。

RIGHT bbox 已是 Stage4 的 160×90 坐标，**没有再次减 y=15**。
使用 `xl=xr+disparity`，9 位加法保存进位，x 饱和到 159、y 饱和到 89。
再映射 x1/y1=左移 3 位，x2/y2=左移 3 位后加 7。
输入 (40,20)-(80,60)，D=8，输出 (384,160)-(711,487)。
仅 `bbox_valid && range_valid` 且非倒置 bbox 绘制三像素内边框。
框内/框外 RGB 透传；右上文字面板是明确的例外，文字优先于重叠框线。
DE=0 或复位时 RGB 完全透传。

右上面板 x=960..1247，y=16..143，复用 `osd_char_lib` 的 16×16 字符并放大 2 倍：

```text
STEREO
V:1
D:08
Z:01000MM
```

距离保留五位十进制，单位 MM；范围 00000..65535。invalid 时 V:0 为粉红文字，
D/Z 清零，不画框。没有增添字库/字符 framebuffer。
16 周期串行 double-dabble 只用寄存器；bbox、valid、数字一起提交，
转换期间保持完整旧结果。输入在转换中更新时随后追上最新值，稳定输入至多 34 周期。
此微小处理延迟之外，测距帧本身早于当前实时视频，仍属于 latest-result overlay。
静止/低速测试适用，未尝试逐帧对齐。

## 修改范围与自检

新增正式 RTL：`td_project/import/stereo_hdmi_overlay.v`、
`td_project/import/stereo_hdmi_result_latch.v`。
两个模块均已注册 UsedInSyn/P&R=true、BelongTo=design_1。
已有 B 文件只改 `user_source/hdl_source/design_top_wrapper.v` 和
`td_project/camera_to_dsi_display.al`；去掉插入块并恢复 RGB 链接后，与备份逐字节相同。
A 全部受保护文件哈希保持一致；B 的 NPU、UDP、测距算法、Frame RAM、约束和小车控制未改。
新增 testbench、脚本、仿真/构建证据集中在 `simulation/stereo_stage7/`。

PASS：Verilog-2005、文件头/ASCII/LF、命名端口/位宽、单驱动、完整组合赋值、同步复位、
无仿真专用设计语句、无占位代码、无新增存储器数组。原生 RTL 报告 LATCH=0。
AXI 握手：N/A。新异步 CDC：N/A（同域）。所有新增状态寄存器复位覆盖。
原生工具 HDL-5106 对纯组合 `adjusted` 位的声明初值提示忽略；这些不是 DFF，
组合块每路径赋值，仿真/综合行为不依赖该初值。

## 仿真与静态检查

| Testbench | 结果 |
|---|---|
| tb_stereo_hdmi_overlay | PASS |
| tb_stereo_hdmi_result_latch | PASS |
| tb_stereo_hdmi_raster | PASS |
| tb_stereo_hdmi_pair | PASS |
| tb_stereo_depth_lut | PASS |
| tb_stereo_roi_ranging | PASS |
| tb_stereo_roi_pair | PASS |

新编译与上述仿真均 0 errors / 0 warnings。
覆盖完整画面框线/内外 RGB、8 倍映射、159/89/255+63 边界、无效和倒置 bbox、
2×字形、0..63 视差、距离 0/9/10/999/1000/10000/65535、原子更新/ID 错配/复位。
扫描测试复用实际顶层新增代码，完整检查两帧全部像素的坐标和零延迟 RGB。
集成测试使用实际 Gray RAM、pair_ctrl、ROI、depth LUT，验证五个完整 pair 的结果。

全 B ModelSim 检查仍有上一阶段记录的
`ph1p35_324_ddr_wrapper.v(61): Undefined variable: dhi_clk` 和 80 条原有 HDMI IP
位宽警告。未修复既有 DDR 问题；原生综合成功不等于全 B ModelSim 检查无错误。
`results.json` 记录该限制，不能将全工程静态检查描述为完全通过。

复现：`python simulation/stereo_stage7/run_stereo_stage7.py`。
构建脚本 `run_b_build.py` 在独立 `b_build` 中执行，不覆盖旧 Runs 或 best_result。
已存在 attempt 时脚本拒绝盲目重复执行。完整实际命令见 `b_build/build_b.tcl`。

## 实际资源与 timing

以下为同类 Optimize-Gate 报告比较（LUT 是工具总 #lut，不能与最终 LUT6 容量混算）：

| 资源 | Stage6 综合 | Stage7 综合 | 增量 |
|---|---:|---:|---:|
| LUT | 23660 | 24123 | +463 |
| SLICE | 18329 | 18697 | +368 |
| ERAM | 105 | 105 | +0 |
| DSP | 17 | 17 | +0 |

**新增 ERAM=0**；仍剩 3 块；DSP 无增加。字符字库也没有推成 ERAM。
布局布线后的实际资源：SLICE=18554, ERAM=105, DSP=17, REG=17815, LUT6=17503。
STA coverage=93.7%，布线最终 SWNS=-1.014 ns, STNS=-188.751 ns, HWNS=0.020 ns, HTNS=0.000 ns。
存在负 slack，不能将构建成功等同于 timing closure；调试文件需在此限制下评估。
最差已报告路径：`stereo_pair_ctrl_inst/found_b17[11]_syn_7.clk (rising edge triggered by clock HDMI_PIXEL_CLK  { rise@0.000000ns  fall@6.666000ns  period=13.333000 })` → `left_gray_frame_buffer_inst/ramread1_syn_23.addra[5] (rising edge triggered by clock HDMI_PIXEL_CLK  { rise@0.000000ns  fall@6.666000ns  period=13.333000 })`，slack=-1.014 ns。
详细证据：`b_build/stage7_gate.area`、`stage7_phy.area`、`stage7_pr.timing`、
`stage7_phy.ts` 和 `build.log`。没有通过放宽约束/修改时钟或双目算法来掩盖时序。
Stage6 没有布局布线结果，不能声称相对 Stage6 的 routed timing 已验证改善/恶化。

## 下板文件与停止点

独立调试文件：`simulation/stereo_stage7/b_build/stereo_hdmi_debug.bit`。
bitstream 已生成，SHA256=839da625223e3df0c3587d5b7458551e8f5142f0bccf9a75d3af1471f759c140。
实际生成文件的大小及哈希见 `final_summary.json`；没有替换旧 best_result。
未下载/控制硬件。下板验证仍需实际 A/B 网络、摄像头和 HDMI 环境。
保留 Stage6 `FB_CONSTANT=8000` 的现有距离换算参数，未重新标定；本阶段验证数字链路。
本阶段工作到此停止。


## 后续 TD 打开工程弹窗：清单字段修复

2026-10-02：新增两个 OSD 文件条目原先缺少 CompileOrder。Windows 独占读写和目录写入测试均通过；同名同路径规则的隔离清单对比中，缺失字段版本原生读取报 PRJ-8640，只补字段的版本读取通过。已仅补充 stereo_hdmi_overlay.v=162、stereo_hdmi_result_latch.v=163；原文件保存在 camera_to_dsi_display.al.before_stage7_compileorder_fix.bak。修复后的实际原工程也已通过 open_project -noanalyze / close_project。没有综合、布局、布线、时序修改或 bitstream 重生成。HDL/约束及 A 的本次开始状态均未改。GUI 弹窗是否消失仍需关闭旧会话并重新打开确认。完整证据在 simulation/stereo_stage7/td_save_diagnosis/results.json。旧构建哈希保留为历史记录，源文件列表和代码未变，仅清单两个字段补齐。
