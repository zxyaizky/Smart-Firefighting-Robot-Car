# 单水平舵机追踪与水泵 GPIO 控制

**2026-10-07 当前恢复自动喷水：** 用户已验证水泵可驱动，明确选择暂不依赖测距。`PUMP_MANUAL_TEST_MODE=0`、`FIRE_PUMP_REQUIRE_DISTANCE=0`。B 板舵机转到火焰目标角度，稳定 200 ms 后再确认 3 次独立有效检测才开泵；左右目标无需回到画面中心。重新转动、火焰有效信号撤销或复位均关泵。SW2 当前不参与控制。详见 `doc/automatic_spray_20261007.md`。下文原“中心锁定 + 距离有效”条件适用于增量模式，位置模式以新报告为准。

**2026-10-06 固定摄像头位置控制：** 用户确认摄像头固定、暂未装喷嘴。顶层 `SERVO_TEST_MODE=0`、`FIRE_SERVO_POSITION_MODE=1`，由新增 `fire_servo_position.v` 按 X 计算有限目标角度，每 100 ms 走 1°，到达后停止。默认 X=40/80/120 分别对应 80°/90°/100°，每 4 像素约 1°，尚需机械方向校准。中心 75～85 的目标角度为 90°；坐标采用三份独立结果的中值抑制单帧异常。该日的中心锁定和距离喷水限制已被上述 2026-10-07 位置喷水规则替代。详见 `doc/servo_position_20261006.md`。下文的原增量闭环说明适用于 `FIRE_SERVO_POSITION_MODE=0`；独立自检分支仍见 `doc/servo_diagnostic.md`。

日期：2026-10-05。按用户最新决定，功能部署在 **B 测距板**：
`C:/Users/lx292/Desktop/test/lab_ex3_osd_SC500_720P/lab_ex3_osd`。
A/NPU 板保持原设计。没有生成或烧录 bitstream。

## 文件和修改范围

新增设计文件，均已注册到 B 的 `.al` 活动综合源列表：

- `td_project/import/servo_pwm.v`
- `td_project/import/fire_aim_controller.v`
- `td_project/import/fire_control_bridge.v`
- `td_project/import/servo_test_controller.v`：仅在 `SERVO_TEST_MODE=1` 时控制舵机。

新增验证文件：

- `simulation/fire_control/tb_servo_pwm.v`
- `simulation/fire_control/tb_fire_aim_controller.v`
- `simulation/fire_control/tb_fire_control_bridge.v`
- `simulation/fire_control/tb_fire_control_integration.v`
- `simulation/fire_control/tb_servo_test_controller.v`
- `simulation/fire_control/tb_servo_diagnostic_pwm.v`
- `simulation/fire_control/tb_fire_control_real_clock.v`：真实 75 MHz 参数下桥、瞄准控制和 PWM 联动，41 项检查通过。
- `simulation/fire_control/run_fire_control.py`
- `simulation/fire_control/results.json`、编译/仿真日志、从真实顶层提取的验证接线片段。

修改原文件仅三个：

1. `user_source/hdl_source/design_top_wrapper.v`：增加两个输出、五个可配置参数、独立自动控制旁路与自检分支；原有模块实例、连接、算法保留。
2. `td_project/camera_to_dsi_display.al`：增加四个 Verilog 设计源条目；testbench 不加入综合列表。
3. `user_source/constraints_source/pin.adc`：初版追加注释候选；随后为修复未约束 IO 的 Bitgen 错误，启用 U1/T4 的两条约束，其他现有约束保留。

本报告是新增 `doc/fire_control.md`。没有改 NPU、检测阈值、双目匹配/测距、HDMI、DDR、MIPI、Ethernet、小车串口或 MAX30102 实现。

## 真实信号与坐标

| 用户概念 | 实际来源 | 位宽/单位 |
|---|---|---|
| `fire_valid` | A 的 `npu_bbox_overlay_160x120.bbox_valid_o`，经原 UDP v2 和 B 的 `stereo_right_capture` 进入 `right_bbox_result_metadata[63]` | 1 位 |
| 火焰 X 框 | `right_bbox_result_metadata[62:55]` / `[47:40]`，对应原 `right_bbox_x1/right_bbox_x2` | 各 8 位，160 像素坐标 |
| `fire_center_x` | 新旁路仅计算已有框 `(x1+x2)>>1`，9 位求和防溢出；输出 `S_fire_center_x` | 8 位，0～159 |
| Y 框 | metadata `[54:48]` / `[39:33]`，对应 `right_bbox_y1/right_bbox_y2` | 各 7 位，0～119；本阶段没有俯仰舵机 |
| 检测身份 | metadata `[32]` 源有效，`[31:16]` 源帧 ID，`[15:0]` NPU 结果 ID | 1/16/16 位 |
| `distance_valid` | 原 `stereo_roi_ranging_inst.range_valid_o` → 顶层 `range_valid` | 1 位，保持电平 |
| `distance_z` | 同模块 `distance_mm_o` → 原顶层 `distance_mm` | 16 位，毫米 |
| 测距完成/身份 | 原 `range_done` / `range_pair_sync_id`；配对接受时快照 `pair_bbox_result_id/pair_right_source_frame_id/pair_sync_id` | 1/16 位 |

没有重做 NPU 解码或火焰分类。原始判定阈值仍由 A 的原检测模块决定。本阶段不依据距离大小改变角度或喷水阈值，只使用既有测距有效状态。

使用 NPU 右目原生 160×120 框，中心为 X=80；不使用 HDMI 上经过视差投影、缩放的左目显示框。新桥拒绝倒序、越界、完全位于原图填充区的框，仅用于执行器授权，不改变原检测和显示。

原 `range_valid` 可以在没有新配对时长期保持 1，所以没有把它单独当成持续喷水许可。只有 `range_done` 对应接受过的配对，且其同步 ID、NPU 结果 ID、右目源帧 ID 与当前火焰结果匹配，桥才给出 `S_fire_distance_valid`。新检测结果立即撤销旧距离授权，必须等待相同结果的新测距完成。

## 时钟、PWM 与控制参数

板级 `I_sys_clk` 实际为 **50 MHz**。B 原 `u_PLL.clk4_out` 接 `S_hdmi_pixel_clk`，`.params_PLL.txt` 的 `CLK4_ACTUAL_FREQ_DISP=75.000000`，因此三个自动控制模块使用 **75 MHz**。PLL 的请求值 74.25 MHz 不能作为实际计数频率。保留的自检分支独立使用板级 50 MHz。

| 角度 | 理论高电平时间 | 75 MHz 高电平时钟计数 |
|---|---|---|
| 0° | 0.5 ms | 37,500 |
| 45° | 1.0 ms | 75,000 |
| 90° | 1.5 ms | 112,500 |
| 135° | 2.0 ms | 150,000 |
| 180° | 2.5 ms | 187,500 |

周期 20 ms = **1,500,000** 个时钟，周期计数器为 21 位，计数 0～1,499,999。实际安全角范围 10°～170°，脉宽计数四舍五入为 **45,833～179,167**，脉宽寄存器为 18 位。

`round(CLK_FREQ_HZ * (500 + angle * 2000 / 180) / 1e6)` 在编译期用 64 位中间量生成常量表，无运行时除法器。20 ms 周期边界才更新脉宽，当前脉冲不会因为中途改变角度而拉长或缩短。复位时 PWM 为低，释放后的首个完整周期命令 90°。

控制每 50 ms 更新一次，即 **3,750,000** 个时钟；每个独立新检测结果最多调整 1°，旧结果不会每 50 ms 反复驱动运动。默认 X<75 减角，X>85 加角，75～85 不动。顶层 `FIRE_SERVO_REVERSE=1` 反转方向。

连续 **3 个独立 NPU 结果** 居中才锁定；重复 UDP 图像中的相同结果不计为新帧。任何无火焰或偏移结果都清除稳定计数。短暂丢失保留当前舵机角度，重新出现后重新获得 3 次稳定结果。

状态为 `IDLE → TRACK → LOCK → SPRAY`。逻辑水泵许可始终要求 `fire_valid && distance_valid && aim_locked`；未经锁定不会启动。默认 `FIRE_PUMP_ACTIVE_HIGH=1`，GPIO 高启动、低关闭；设为 0 时 GPIO 低启动、高关闭。

收到无火焰/非法结果、偏心结果、原测距有效位下降、像素域 ABORT/读欠载或复位，立即撤销喷水许可，**不等待 50 ms 更新周期**。所有结果和故障均使用既有 75 MHz 域；没有直接跨域使用 125 MHz UDP 错误短脉冲。

没有新独立检测或匹配测距时，默认 **5 秒** 超时关闭；相同结果重传不能刷新超时。`FIRE_RESULT_TIMEOUT_MS` 可调，应根据真实 NPU 输出间隔设定更合适的值。断流时只能在故障通知或超时后关闭；没有新检测时，硬件无法在真实火焰消失瞬间得知。每次新的测距接受都会让原 `range_valid` 暂时为 0，因此正常测距期间喷水也可能短暂停止，这是优先关闭的保守行为。

## GPIO 与约束

原板卡引脚表渲染 `.docx_pin_render/page-2.png` 与 3.3 V BANK21 原理图核验：

| 建议用途 | B 板排针 | GPIO 名称 | FPGA 管脚 |
|---|---|---|---|
| `servo_pwm_out` | J1 第 4 脚 | GPIOA_3 | U1 |
| `pump_ctrl_out` | J1 第 5 脚 | GPIOA_4 | T4 |
| 备选 | J1 第 6 脚 | GPIOA_5 | T3 |

这些未被当前有效约束占用。J1 的 1/2/3 已分别用于小车 RX、双目同步、小车 TX，不可复用；C18/D15 已用于 MAX30102。

初版按“先不要随便指定”要求保留注释约束。用户随后报告未约束 IO 导致 Bitgen 失败，因此已按前述接线启用：`servo_pwm_out=U1/J1.4`、`pump_ctrl_out=T4/J1.5`，LVCMOS33，水泵默认下拉。需要重新布局布线再执行 Bitgen，让修改后的约束进入新的物理数据库。此修复没有烧录板卡；实物接线应采用这两个排针位置。其他 GPIO 需同时核对 VCCIO 和现有外设。

## 实际接线

1. `servo_pwm_out` 对应 GPIO → 舵机信号线。舵机 V+ → 符合舵机标称电压、能供应启动/堵转电流的外部稳压电源；舵机 GND → 电源负极，并与 FPGA GND 共地。GPIO 只供信号，不给舵机供电。
2. `pump_ctrl_out` 对应 GPIO → MOS 模块 IN/控制端。MOS 模块必须能接受 3.3 V 逻辑；要求其他逻辑电平时使用电平转换，不将 5 V 接到 FPGA GPIO。
3. 水泵接 MOS 模块负载端，泵电源接模块电源端，电压和电流按水泵/MOS 模块规格；泵的工作电流只流经电源与 MOS 负载回路。常见共地模块的控制 GND、电源负极与 FPGA GND 共地；隔离模块按其说明接线。
4. 高电平有效配置，在 MOS IN 外部加下拉，使 FPGA 未配置/高阻时保持关闭。反相模块使用相应外部上拉和 `FIRE_PUMP_ACTIVE_HIGH=0`，约束中的 PULLTYPE 也改为 PULLUP。
5. 检查 MOS 模块是否已包含电机续流保护；没有时在水泵两端加适用续流二极管，阴极接泵正端、阳极接泵负端，并按模块规格处理滤波/去耦。

原增量模式的机械前提：**双目摄像头组件与喷嘴应随水平舵机共同转动，并保持相机相对位置和已标定基线。** 固定摄像头目前应使用新默认的 `FIRE_SERVO_POSITION_MODE=1`，目标角度基于画面位置计算，到达即停。后续装喷嘴时仍需校准像素位置、舵机方向和喷嘴中心方向。新位置模式没有实际舵机反馈，指令到位并等待不能替代物理瞄准验证；画面偏心时仍受原水泵中心锁定条件限制。

## 验证与限制

ModelSim SE-64 2020.4，新增 RTL 使用 Verilog-2005 的 Verilog-2001 兼容写法。

- 新增模块与四个 testbench 编译：**0 错误，0 警告**。
- 五组运行全部 PASS：PWM；追踪/锁定/安全关闭；身份与新鲜度桥；真实顶层接线；顶层反向舵机+低有效水泵。
- PWM 测试采用真实 100/75/50 MHz 周期计数，五个角度全部检查；实际硬件安全夹限保持启用，端点测试实例单独放宽为 0°～180°。
- 控制单测 26 项，桥单测 32 项，两个集成配置各 21 项检查。集成接线直接从修改后的顶层提取，仅在仿真片段中缩小计时频率以加速。
- B 全活动源码由 108 增为 111 个；比较修改前后，新增语法诊断为 **0**。全工程仍有原 `ph1p35_324_ddr_wrapper.v:61` 的 `dhi_clk` 未声明错误，以及原 HDMI 加密 IP 的 80 条位宽警告。本次没有改受保护 DDR 链路，**不能宣称全工程已通过编译或可直接出 bitstream**。
- 原双目 ROI/gradient 六项 PASS；原 HDMI latch/overlay/pair 三项 PASS。一项旧 raster fixture 在原 B 源码上已经失败，因未驱动后来新增的 result_seen/update_count 等端口，不能计作通过，也不归因于新增控制。详细旧回归日志保存在原工作目录 `fire_control_delivery/regression_logs`。

重跑新增验证：

```powershell
python C:\Users\lx292\Desktop\test\lab_ex3_osd_SC500_720P\lab_ex3_osd\simulation\fire_control\run_fire_control.py
```

需要 PATH 中有 `vlib/vlog/vsim`。此脚本只执行软件仿真与静态源检查，不调用综合、布局布线、bitgen 或下载。没有验证实际机械方向、电源、引脚电平、板上运动、FPGA 资源占用或 STA；启用约束并处理已有工程编译问题后才能进入后续上板流程。

自检：文件头/Verilog 语法/显式 reg-wire/单驱动/无锁存器/同步复位/同域输入均通过；复位覆盖全部控制寄存器；无 AXI 接口。没有 PID、俯仰舵机或 NPU/测距算法改动。
