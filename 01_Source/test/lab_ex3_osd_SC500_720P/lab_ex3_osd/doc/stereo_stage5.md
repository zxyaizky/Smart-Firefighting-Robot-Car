# 双目第 5 阶段：Gray 帧缓存和 sync_id 配对

日期：2026-10-02。仅 B 工程；行为仿真和静态检查。

完成 LEFT/RIGHT 各两个 Gray bank、完整帧提交、配对预留/锁定、随机同步读。
未实现 SAD、视差、距离、HDMI 测距显示或小车控制。未运行综合、布线、下载。

## 1. 新增文件

工程 RTL：

- `td_project/import/stereo_gray_frame_buffer.v`
- `td_project/import/stereo_pair_ctrl.v`

行为测试和可复现入口：

- `simulation/stereo_stage5/tb_stereo_gray_frame_buffer.v`
- `simulation/stereo_stage5/tb_stereo_frame_pair.v`
- `simulation/stereo_stage5/tb_stereo_frame_pair_pipeline.v`
- `simulation/stereo_stage5/stereo_stage5_fixture.vh`：从实际新增顶层连接生成。
- `simulation/stereo_stage5/make_test_fixture.py`：只生成仿真 fixture。
- `simulation/stereo_stage5/run_stereo_stage5.py`：新的仿真/静态审计入口。
- 本报告 `doc/stereo_stage5.md`。

测试源没有注册到设计综合清单。仿真库、日志、基线和复核块保存在
`simulation/stereo_stage5/`；未向 A 写入任何测试输出。

## 2. 修改文件和范围

只修改两个已有 B 文件：

- `user_source/hdl_source/design_top_wrapper.v`：追加两个 buffer 实例、一个
  pair controller 实例及内部调试线；没有改变外部端口或已有模块连接。
- `td_project/camera_to_dsi_display.al`：增加上述两个 RTL 的 source entry，
  `UsedInSyn=true`、`UsedInP&R=true`、`BelongTo=design_1`，没有 AutoExcluded。

从当前文件移除精确新增块后，与阶段开始保存的原文件逐字节相同。
保护源 SHA256 审计确认：A 的 RTL/约束/清单/测试源没有变化；B 的旧 RTL
仅顶层增加连接。LEFT sampler、RIGHT capture、UDP v2、Ethernet RX、sync generator、
NPU、MIPI、DDR、HDMI、小车控制及引脚/时序约束均未修改。
本阶段没有发现需要修改旧接口的 bug。

## 3. Frame RAM 结构

统一 `stereo_gray_frame_buffer` 实例化两次，分别服务 LEFT 和 RIGHT。
每个实例有两个独立的 8-bit 简单双端口 RAM：一个同步写端，一个同步读端。
四个逻辑 bank 分别是 LEFT0、LEFT1、RIGHT0、RIGHT1。

写端连续地址计数器为 14 bit。每个合法 pixel 前检查输入 x/y 等于内部 raster
期望位置，随后地址递增；x 到 159 后清零并使 y 加一。没有 y×160 通用乘法器。
START 可与第一个 pixel 同拍；END 可与最后一个 pixel 同拍，也可晚于最后 pixel。
实际 LEFT 是 START+首 pixel；实际 RIGHT 是 START 后先等待黑边裁剪结束。

## 4. 单 bank bit 数

有效图：160×90×8 = **115200 bit = 14400 byte**。

为了遵循工程现有的精确地址位宽 RAM 模板，RTL 声明每个数组为
16384×8，即 **131072 bit = 16384 byte**。只允许 0..14399 的有效访问，
14400..16383 不可写、读请求不产生 valid。每 bank 有 1984 byte 未使用空间。
区分图像的逻辑容量与数组声明容量，不能把数组空间全部当作有效图像。

## 5. 总逻辑缓存容量

四幅有效图：**57600 byte = 460800 bit**。
四个数组声明容量：**65536 byte = 524288 bit**。
每 bank 的 metadata/valid 另用少量寄存器，不占图像地址。
LEFT 每 bank metadata 33 bit；RIGHT 每 bank metadata 96 bit。

## 6. ERAM 数量估算和推断依据

复用 `td_project/import/fm_bank_array.v` 的分 bank SDP 模板：
`syn_ramstyle="block_ram"`、`ram_style="block"`，分别用时钟 always 块完成写和读。
没有数组 reset、异步数组读或整幅 LUT RAM 编码。

本地厂商生成的 `td_project/al_ip/blk_mem_gen_0/blk_mem_gen_0.v` 使用 8-bit 数据、
11-bit 地址、1280 深度；其 `RTL/ram_d5bf2e66b253.v` 选择 PH1P_LOGIC_ERAM 的
`IMPLEMENT="20K"`。历史日志 `td_project/td_20260913_185649.log` 中也有
2048×9、PDPW、20K(FAST) 的宏配置。

据此按 20K ERAM 的 2048×8/9 深度配置估算：16384/2048 = **8 块/bank**，
四 bank 约 **32 块 ERAM**。这是配置/深度推算，不是综合资源结果；按总 bit 数
直接除以 20K 会忽略位宽/深度配置及数组尾部空洞，不能视为实际块数。
映射器是否裁掉未用地址、选择其他配置，以及 debug-only 顶层是否保留所有 RAM，
必须在以后获准综合且连接实际消费者后确认。本阶段不声称 ERAM 推断已经验证，
不声称器件资源能够最终放下。没有删除旧 Ethernet HDMI framebuffer 来腾出资源。

## 7. RAM 读接口和延迟

每个 buffer 提供 `rd_en_i`、`rd_bank_i`、`rd_addr_i[13:0]`，返回
`rd_valid_o`、`rd_data_o[7:0]`。

**同步读，一拍延迟**：地址/使能在时钟边沿采样，数据和 valid 在该边沿之后的
周期有效。bank select 同时打一拍，再选择对应 bank 的同步数据；可每拍切换 bank。
请求必须指定 committed bank 且地址 <14400；否则 valid=0，此时数据无需解释。
可读已提交未锁定的 bank，但消费者应只用 controller 交付的 pair bank。

所有新增模块都使用 `S_hdmi_pixel_clk`，同步高有效 reset 为 `~S_hdmi_rst_n`。
现有 LEFT 的 `S_video_out_rst_n` 已直接等于 `S_hdmi_rst_n`，RIGHT 也是该复位源。
现有跨时钟处理发生在上游，此处没有新 CDC。未来换成其他读时钟时不能直接跨域。

## 8. bank 状态和提交

状态行为：FREE → WRITING → COMMITTED → RESERVED/OFFER → LOCKED/ACTIVE → FREE。
图像数组不 reset；reset 清 valid/控制/metadata/统计，未提交数据不可读取。

- START 只分配原本 FREE 且未 lock 的 bank，原子锁存 metadata；不设置 valid。
- 14400 个像素且正常 END 后才置 bank valid、增加 committed count。
- ABORT、短帧 END、额外 pixel、坐标错误、写入期间新 START 均拒绝当前帧，
  不提交。先前完整 bank 不变。重叠的新 START 也不作为完整新帧接收。
- 无可用 bank 的 START 丢弃整幅输入帧，不对锁定/已提交 bank 写入。
- writer 从不自行覆盖 committed bank，只有 controller 可 release/discard。
- 同拍 release 和新 START 不提前复用刚释放 bank，下一拍才可分配。
- 为保障 valid/accept 等待期间的图像稳定，OFFER 已预留两个 bank；accept 后
  进入 ACTIVE，done 才释放。单纯 done、done-before-accept 不会释放 OFFER。

buffer 内写状态 IDLE/ACTIVE/DROP 与 bank valid、外部 lock 掩码共同实现上述语义，
不需为每个 bank 增加复杂状态机。

## 9. pair 匹配和握手

controller 同时看到双方两个 committed bank，搜索全部四种组合。
只允许 sync_valid 双方为 1 且 sync_id 严格相等。source ID 分别保留，完全不比较
LEFT source ID 与 RIGHT source ID 是否相等。bbox_valid=0 也可配对。
如同时已有两个可配对 ID，在有效 half-range 范围内先交付较旧 ID。

pair_valid 保持到 pair_accept，整个 OFFER 期间 metadata 和 bank 选择稳定。
accept 边沿产生一拍 pair_start，增加 pair_count，进入 ACTIVE，并更新
last_pair_sync_id 水位；ACTIVE 期间 pair metadata 仍保持稳定。
done 边沿释放恰好这两个 bank。其他已经提交的 bank 不会被 done 误释放。
accept 与 done 同拍时只处理 accept，done 需在 ACTIVE 周期再次到达。
reset 是当前唯一显式开始新 epoch 的方式。

## 10. stale/drop 策略及统计

空闲调度时首先丢弃 sync_valid=0 和不比已接受水位更新的 committed bank。
先搜索精确匹配，存在匹配就预留，不因其他较新 bank 而错删已匹配帧。
没有精确匹配时，对端已经前进的旧帧被判为 unmatched。
若同侧两个 bank 都 committed 而对端暂未提供匹配，回收较旧 bank，保留最新完整帧；
未配对重复 ID 保留 bank0。对端永远缺失也不会无限积压。

OFFER/ACTIVE 期间不清除 spare committed bank，保留一幅后续完整帧等待当前 pair done。
该侧若一个 bank 锁定、另一个也 committed，再来 START 即 no-free/drop。
本策略是有界、允许丢帧的缓冲，不保证任意时延/乱序下保存所有同步请求。

统计都在像素时钟域，32 bit 模 2^32：

| 信号 | 精确定义 |
| --- | --- |
| left/right_committed_count | 对应 buffer 成功 END 提交次数，包括随后被调度丢弃的帧 |
| left/right_drop_count | 对应 buffer 拒绝的输入帧 + controller 丢弃的 committed bank 数；正常 done 不算 drop |
| pair_count | 成功 pair_accept 次数；仅 OFFER 不计入 |
| pair_mismatch_drop_count | controller 丢弃 bank 总数，包括 stale、duplicate、水位过旧、无 sync 和半范围歧义；按 bank 计数 |
| pair_busy_drop_count | 双侧 no-free START 次数之和；包含 OFFER 预留和 ACTIVE 锁定期间，不包括像素格式错误 |
| last_pair_sync_id | 最近成功 accept 的 sync ID；reset 后 0，内部另有水位有效位 |

输入帧拒绝只计一次，之后 drain 状态忽略该帧余下数据；无效态孤立 pixel/END/ABORT
不计成一幅输入帧。buffer 本身无 idle timeout，上游两 sampler/capture 已提供 timeout ABORT。

## 11. sync 回绕、重复及 half-range 限制

使用 16-bit `delta=new-old`；只有 1..32767 是 forward，FFFF→0000 是合法前进。
已经 accept 的 sync ID 不能再次配对；旧/重复 ID 由水位拒绝。reset 后清水位，可再用旧 ID。

delta=32768 不建立时间先后：相对已配对水位的帧拒绝；没有匹配且左右相差 32768 时
双方都丢弃；同侧两幅相差 32768 且没有匹配时也都丢弃。
控制器不自动猜测断联后的新 epoch。无 epoch 标记时，长时间间隔超过半范围或任意
大跨度跳号无法可靠区分前进和旧重放，需要系统 reset/重新建立 epoch。

## 12. bbox 和 RIGHT bank 绑定

metadata packed layout 的低位先后如下：

| 字段 | LEFT 位段 | RIGHT 位段 |
| --- | --- | --- |
| sync_valid | 0 | 0 |
| sync_id | 16:1 | 16:1 |
| source_frame_id | 32:17 | 32:17 |
| bbox_valid | 无 | 33 |
| bbox_x1 / bbox_y1 | 无 | 41:34 / 48:42 |
| bbox_x2 / bbox_y2 | 无 | 56:49 / 63:57 |
| bbox_result_id | 无 | 79:64 |
| udp_frame_id | 无 | 95:80 |

RIGHT capture 已验证 bbox 与其 source ID 关联并完成裁剪。本阶段保存其现成 bbox_valid，
不重新恢复框、不比较红色像素、不改变 UDP metadata。
START 时写入被分配 bank 的 metadata；同一个 bank 的 valid 只在合法 END 后出现。
controller OFFER 时再快照被选 RIGHT bank 的整套 metadata，之后上游写入 41 不会
改变 pair 40 的 bbox/UDP ID/图像选择。

## 13. 所有 testbench 结果

ModelSim SE-64 2020.4，新运行 **18 个独立 testbench 全部 PASS**。
四个回归库的 vlog 与行为模拟均无错误、无警告。

| 阶段 | testbench | 结果 |
| --- | --- | --- |
| 5 新增 | tb_stereo_gray_frame_buffer | PASS |
| 5 新增 | tb_stereo_frame_pair | PASS |
| 5 新增 | tb_stereo_frame_pair_pipeline | PASS |
| 4 | tb_stereo_right_capture | PASS |
| 4 | tb_stereo_gray_equivalence | PASS |
| 4 | tb_stereo_right_udp | PASS |
| 2 | tb_stereo_sync_gen | PASS |
| 2 | tb_stereo_sync_selector | PASS |
| 2 | tb_stereo_udp | PASS |
| 2 | tb_stereo_identity | PASS |
| 2 | tb_stereo_bbox | PASS |
| 2 | tb_video_udp_tx | PASS |
| 2 | tb_npu_bbox_threshold | PASS |
| 3 | tb_stereo_left_selector | PASS |
| 3 | tb_stereo_left_sampler | PASS |
| 3 | tb_stereo_left_identity | PASS |
| 3 | tb_stereo_left_vtc | PASS |
| 3 | tb_stereo_left_page_errors | PASS |

`tb_stereo_frame_pair` 覆盖用户指定十项：10 正常；11 右先；12/13 mismatch；
20/22/23 丢 21；左右 ABORT 保留前帧；30 长期锁定/新帧 drop；两眼边界与随机读；
40 图像/bbox 同 bank（新 41 写入时仍读 40）；FFFE/FFFF/0000/0001；50 重复抑制及 reset 重用。
另外覆盖 OFFER 未 accept 的保护、短/超长/错坐标、14400 后 ABORT、无 sync、无 bbox、
half-range 歧义、过早 done、peer silent 和 ACTIVE reset。

`tb_stereo_gray_frame_buffer` 完整遍历两个 bank 共 28800 次合法随机地址接口读取，
每拍交替 bank；覆盖所有 1984 个无效尾部地址、START 后 metadata 变化、ABORT、
no-free、release+START 同拍、新 START 覆盖、reset 与控制同拍。

`tb_stereo_frame_pair_pipeline` 接入真实 LEFT sampler（1280×720 RGB 输入）和
RIGHT capture（160×120 RGB 输入），其实际输出直接进入与顶层相同的两个 RAM/
pair controller。LEFT source=153、RIGHT source=81、sync=20，验证完整 14400 个
左右 RAM 读值与源 Gray 参考逐点一致、当前 bbox 裁剪、accept/start/done 释放。
该测试从 RGB/重组流边界开始，不包括物理 MIPI/以太网 PHY 的电气仿真。

静态检查：新增两模块正式 source entry、三个实例所有 named ports、Verilog-2005
语法/基本风格及保护源审计 PASS。全清单 vlog：A 108 文件，0 error/80 个既有
HDMI 加密 IP 警告；B 104 文件，仍有 **1 个既有错误**：
`ph1p35_324_ddr_wrapper.v(61): Undefined variable: dhi_clk`，及相同 80 个既有 IP 警告。
新增模块编译无错误。不能把 B 全工程静态编译报告为零错误；该旧 DDR 问题未修改。

证据：`simulation/stereo_stage5/results.json`、`changes.json` 及相应 compile/test/syntax 日志。
重跑入口：在该目录执行 `python run_stereo_stage5.py`；仅调用 vlib/vlog/vsim。
审计以阶段开始的保护源为基线，若以后阶段修改源码，当前范围审计应失败，不能当作新阶段结果。

## 14. 当前完整链路

```text
B stereo_sync_gen request #N
    ├─ 本地请求 CDC/DDR page identity → clean local video → stereo_left_sampler
    │       → LEFT 160×90 Gray8 / sync=N / source=B_id
    │       → left_gray_frame_buffer_inst (bank0/1)
    │
    └─ GPIO → A next-frame selector → DDR page / clean sampler → UDP v2
            → B Ethernet RX / video_udp_rx → stereo_right_capture
            → RIGHT 160×90 Gray8 / sync=N / source=A_id / bbox
            → right_gray_frame_buffer_inst (bank0/1)

    两侧 committed bank metadata
            → stereo_pair_ctrl_inst
            → held pair_valid / pair_sync_id=N / bank indices / source IDs / bbox
            → pair_accept → pair_start / ACTIVE locks → pair_done → release

    selected LEFT bank + rd_en/rd_addr → rd_valid/Gray8 (1 clock)
    selected RIGHT bank + rd_en/rd_addr → rd_valid/Gray8 (1 clock)
```

## 15. 已知限制及阶段停止位置

- 顶层尚无 SAD 消费者：pair_accept=0、pair_done=0，读 enable=0/addr=0。
  内部 keep debug 线保留供后续连接；真实硬件会停留在首个 OFFER，spare bank 满后
  继续输入会按 no-free 丢帧。这是当前阶段的明确行为，不模拟算法自动消费。
- 两 bank/眼只能保留当前 pair 和有限后续帧；不保证无限乱序或无限处理阻塞下不丢帧。
- 仅 half-range ordering，epoch 重新开始需要 reset；当前无新协议或自动重同步。
- 本阶段只证明 RTL 行为。ERAM 实际映射/余量、资源总量、时序和硬件行为未验证；
  debug-only 常量连接可能影响后续综合保留，需要接消费者时检查。
- generic buffer 无独立 idle timeout；正常接入依赖已有上游 ABORT。直接用户若停止
  提供 pixel/END/ABORT，会占用 WRITING bank，需补控制或 reset，不能读取未提交图。
- B 的既有 `dhi_clk` 静态错误保留，后续完整工程构建前需在另行授权范围处理。
- A 的历史 manifest drift 仍是第 3.5 阶段的 RESOLVED 状态，没有新增 REVIEW_REQUIRED。

第 5 阶段到此停止，不开始 SAD 或其他后续双目功能。
