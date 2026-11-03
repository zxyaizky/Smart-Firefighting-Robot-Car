# B 板绿色框覆盖改善（2026-10-06）

本轮针对 B 测距板 HDMI 上的绿色框。新增有限边距、完整矩形裁剪和垂直消隐期间的整组更新，保留原测距有效条件。A/NPU 的检测算法和原始检测框、B 的双目匹配/测距、舵机、水泵、GPIO 约束及视频主链路未改动。

实际修改的 B 工程在：

`C:\Users\lx292\Desktop\test\lab_ex3_osd_SC500_720P\lab_ex3_osd`

请使用该目录的 `td_project/camera_to_dsi_display.al`，当前工作区中另一份 A/NPU 工程没有接入本轮改动。

## 原因及本轮处理

原绿色框直接把 160×90 的右图检测框加上已有视差，再放大八倍绘到 B 的 1280×720 左图。原实现没有覆盖边距；距离转换结束后可在正在扫描的一帧中途换框；两个 X 端点独立饱和还会把完全移出画面的矩形压成右边缘细框。

现在独立的 `stereo_bbox_projector.v` 完成显示投影。沿用现有正向关系 `left_x = right_x + disparity`、原有稳定视差、原有裁掉 NPU 上下填充后的 160×90 坐标和八倍缩放，不改变匹配搜索或结果来源。

左右边距由原检测框宽度计算，上下边距由高度计算，均在原 160×90 单位中计算：

```text
width  = x2 - x1 + 1
height = y2 - y1 + 1
pad_x  = min(8, 2 + ceil(width  / 16))
pad_y  = min(8, 2 + ceil(height / 16))
left_x1 = x1 + disparity + offset_x - pad_x
left_x2 = x2 + disparity + offset_x + pad_x
left_y1 = y1 + offset_y - pad_y
left_y2 = y2 + offset_y + pad_y
```

先判断投影后的完整矩形是否与图像相交，再裁到 X=0…159、Y=0…89，最后乘 8；右/下端点再加 7，覆盖对应的完整采样单元。默认每边扩展 24…64 个 HDMI 像素，碰到图像边界时裁剪。

框、视差、距离数值经过原来的 16 拍 BCD 转换后作为一组待显示结果保存，仅在现有 `S_logo_out_vsync` 有效的垂直消隐期间发布，活动画面扫描期间不换框。RGB 通路仍为组合逻辑，未增加像素延迟，HDMI 的 VS/HS/DE 连线未改。

## 可调参数

参数集中在 B 顶层 `design_top_wrapper.v`：

| 参数 | 当前值 | 含义 |
| --- | ---: | --- |
| STEREO_BOX_COVERAGE_ENABLE | 1 | 启用边距及完整矩形裁剪 |
| STEREO_BOX_FRAME_ATOMIC | 1 | 垂直消隐期间统一发布框与文字 |
| STEREO_BOX_PAD_BASE_PIXELS | 2 | 每边基础边距，原 160×90 像素单位 |
| STEREO_BOX_PAD_REL_SHIFT | 4 | 相对边距采用向上取整的宽/高除以 16 |
| STEREO_BOX_PAD_MAX_PIXELS | 8 | 每边总边距上限，HDMI 上对应 64 像素 |
| STEREO_BOX_OFFSET_X_PIXELS | 0 | 水平安装补偿；正数使显示框右移 |
| STEREO_BOX_OFFSET_Y_PIXELS | 0 | 垂直安装补偿；正数使显示框下移 |

每改 1 个 offset 单位，HDMI 框平移 8 像素。当前没有两摄像头的实测标定信息，偏移保持 0。如果新文件下板后整个框仍持续向某方向偏移，需要根据实际画面调整偏移；扩边不能修复错误的原始检测或错误视差。

设 `STEREO_BOX_COVERAGE_ENABLE=0` 可关闭覆盖改善，恢复旧投影。再将 `STEREO_BOX_FRAME_ATOMIC=0` 可恢复旧显示发布时间。独立模块默认关闭两项功能，B 顶层明确启用，原历史行为仍可回归验证。

## 显示与执行控制的边界

绿色框仍要求原来的 `result_seen && bbox_valid && range_valid`。距离失效时不会因为扩大显示框而伪造有效测距；也没有为视觉稳定而保持失效框。失效结果在下一个可发布的消隐窗口更新到显示。

舵机继续使用原始火焰坐标，水泵继续使用原来的检测、瞄准和距离联锁。本轮扩大后的框没有送回测距或控制模块。自动追踪参数 `SERVO_TEST_MODE=0` 保持不变。

原有 logo 和状态文字区域保留绘制优先级，绿色边框经过这些区域时仍可能被局部遮挡。这是原有 UI 的覆盖规则。也保留距离无效时不显示绿色框的规则，所以本轮不能保证每次出现 A 检测框就一定出现 B 绿色框。

## 文件

新增综合源文件：

- `td_project/import/stereo_bbox_projector.v`

修改原工程文件：

- `td_project/import/stereo_hdmi_overlay.v`：投影模块、整组待发布寄存器和消隐期间发布。
- `user_source/hdl_source/design_top_wrapper.v`：七个显示参数及现有 VS 接入。
- `td_project/camera_to_dsi_display.al`：登记新增投影模块，加入综合和布局布线清单。

新增 `simulation/stereo_bbox_coverage/`：

- `tb_stereo_bbox_projector.v`：投影、比例边距、裁剪、偏移、非法框、旧模式等。
- `tb_stereo_bbox_coverage_top.v`：直接使用当前顶层参数和实际 overlay 接入片段，整帧检查。
- `run_tests.py`：生成顶层片段、运行新仿真和隔离的旧回归、对比完整工程语法诊断及修改范围。
- 生成的 `coverage_top_params.vh`、`coverage_top_overlay.vh`。
- 隔离的旧回归文件、运行日志、`results.json` 及仿真光栅 `coverage_raster.ppm`。

旧的历史 testbench 文件保持原样。所有新增源文件及运行记录均保存在实际 B 工程，不需要修改 A 工程。

## 验证记录

使用已安装的 ModelSim；新增显示相关源文件按 Verilog-2005 编译，0 errors / 0 warnings。四项仿真均 PASS：

| 仿真 | 结果 |
| --- | --- |
| tb_stereo_bbox_projector | 18,514 组输入、16 种参数配置、462,590 次检查 |
| tb_stereo_bbox_coverage_top | 4 帧全像素扫描、7,387,214 次检查 |
| tb_stereo_hdmi_overlay_legacy | 2,019,710 次检查，原尺寸、字形、RGB 行为回归 |
| tb_stereo_stable_label_overlay | 18 组场景、3 帧扫描、2,838,844 次检查 |

整帧验证覆盖：活动画面中到来的新框等到消隐才发布、框/文字/视差同组变化、边缘裁剪、完全离屏不画假框、距离失效、火焰无效、复位、原 UI 优先级、无效 DE 和零像素延迟。

同时按工程清单检查当前 112 个有效 .v 文件，诊断与修改前基线相同：原 DDR 封装 `ph1p35_324_ddr_wrapper.v(61)` 的 `dhi_clk` 未定义错误，以及原 HDMI 封装的 80 条警告。不能据此声称完整工程 ModelSim 编译已通过；本轮显示模块编译和四项仿真通过，完整工程未增加语法诊断。没有修改原 DDR/HDMI 封装来绕过基线问题。

对比修改前源文件 SHA256：A 的 251 个受保护文件全部不变，B 的 270 个受保护原文件仅上述三个文件变化；测距、火焰控制、舵机、水泵、pin.adc、时钟约束和原视频/Ethernet 核心文件保持原样。

可复现命令（ModelSim 的 vlib/vlog/vsim 需在 PATH 中）：

```powershell
cd C:\Users\lx292\Desktop\test\lab_ex3_osd_SC500_720P\lab_ex3_osd\simulation\stereo_bbox_coverage
python .\run_tests.py
```

## 下板步骤

本轮没有运行综合、布局布线、Bitgen 或烧录，现有旧下载文件不包含这些改动。

1. 在 TD 中重新打开上面的 B 工程 .al，确认源文件列表包含 `stereo_bbox_projector.v`。
2. 重新完成综合、布局布线及位流生成，并检查新布局布线时序报告。本轮 RTL 仿真没有验证新布局布线时序。
3. 使用新生成的文件下载 B 板，A 板保持现有运行文件。
4. 对比火焰位于左、中、右和图像边缘时的覆盖。先判断是框偏小还是整体偏移，再调整边距或 offset。

备份和审阅差异位于当前工作区 `fire_control_delivery/stereo_bbox_coverage_20261006`。本轮不更换舵机或水泵引脚，也不改变接线。
