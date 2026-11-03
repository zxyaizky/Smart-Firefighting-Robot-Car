# 双目第 6 阶段：YOLO 单目标中心模板直接测距

日期：2026-10-02。B 工程实现、行为仿真、一次实际综合。

结果：RIGHT bbox 中心 5×5 → LEFT 正向水平对应搜索 → 单个 disparity →
参数化距离 LUT → `range_valid` / `distance_mm`。结果目前只接内部 debug wires。
没有整幅 disparity/depth map、SGM/SGBM/Census、多点 median、矫正、亚像素、HDMI DIST
或小车距离控制；没有布线、bitstream 生成或下载。

## 1. 开源项目实际参考内容

只读分析本地 `C:/Users/lx292/Desktop/FPGA-DepthMap-Basys3-320x240/`：

- `README.md`：整体 block matching、窗口搜索、最小代价决定 disparity 的说明。
- `depthMap.srcs/sources_1/imports/disparity_generator.v`：窗口循环内累加平方差，
  `ssd < prev_ssd` 更新 best_offset，并逐像素输出整图 disparity。
- 同目录 `disparity_generator.vhd`：分块缓存、水平 offset 搜索、平方差展开、
  最小代价更新及图像写输出。

README 将项目称为 SAD，但所读两个源实现使用的是 **SSD，平方差**。VHDL 版本
虽有 window=5 generic，实际活动的展开式是 3×3 邻域八项（右下项被注释），
不能据 generic 声称该版本实际计算完整 5×5。其原方向是 LEFT(x,y) 对 RIGHT(x-d,y)，
本阶段根据用户定义采用等价对应关系 RIGHT(cx,cy) 对 LEFT(cx+d,cy)。

实际参考的是：沿水平轴改变候选偏移、比较小块对应区域、选择最小代价。
当前 160×90、一个目标、约 5Hz 请求适合完全串行的 5×5 绝对差累加；不用参考项目
的并行 SSD、完整图像遍历、Xilinx 缓存和输出架构。README 内有关 BRAM 的概括
不作为当前 Anlogic RAM 实现依据，当前使用已验证的随机同步读接口。

## 2. 是否复制源文件

**没有复制任何开源源文件，参考算法思路重新实现。**
没有把参考 repo、Camera/VGA/Basys3 top、Clock IP、Xilinx RAM IP 或完整 disparity
pipeline 注册到 B。`reference_hashes.json` 和最终审计证明参考目录未发生变化。

## 3. 新增/修改文件及清单恢复

新增工程 RTL：

- `td_project/import/stereo_roi_ranging.v`
- `td_project/import/stereo_depth_lut.v`

新增验证：

- `simulation/stereo_stage6/tb_stereo_roi_ranging.v`
- `simulation/stereo_stage6/tb_stereo_depth_lut.v`
- `simulation/stereo_stage6/tb_stereo_roi_pair.v`
- `simulation/stereo_stage6/stereo_stage6_fixture.vh`：实际 Stage5 连接加新消费者。
- `simulation/stereo_stage6/run_stereo_stage6.py`
- `simulation/stereo_stage6/run_b_synthesis_once.py`
- 本报告。

既有 B 文件仅修改：

- `user_source/hdl_source/design_top_wrapper.v`：去掉 Stage5 六个输入的常量绑值，
  接测距模块的 accept/done、read enable/address；两个读 bank 改接测距快照输出；
  增加测距实例和 debug 线。外部端口、HDMI/NPU/DDR/小车连接未改变。
- `td_project/camera_to_dsi_display.al`：新增两个正式 RTL 条目，UsedInSyn/P&R=true，
  BelongTo=design_1，无 AutoExcluded。

工作期间 B 的 `.al` 出现外部清单回退。文件证据确认只有九个既有条目被删除，
其余字节与阶段开始一致，已仅补回：stereo_sync_gen、stereo_metadata_fifo、
stereo_metadata_mailbox、stereo_left_frame_selector、stereo_left_video_tap、
stereo_left_sampler、stereo_right_capture、stereo_gray_frame_buffer、stereo_pair_ctrl。
移除两个新条目后，B 清单精确恢复阶段开始 SHA256。
`B_manifest_drift.json` 为 RESOLVED。用户确认 TD GUI 当时已打开；实际文件写入者
仍无法只凭文件差异确定。请关闭旧 GUI 工程时不要保存，再重新打开当前 B `.al`，
使 GUI 使用当前清单。

Frame RAM、pair_ctrl、采样器、协议、Ethernet RX、约束及所有其他旧 B RTL 未改。
没有修复旧 DDR `dhi_clk` 声明问题或重构其他模块。

## 4. stereo_roi_ranging 完整接口

所有控制/数据均在 `S_hdmi_pixel_clk` 域，`rst` 为同步高有效；顶层为 `~S_hdmi_rst_n`。

| 端口 | 方向/位宽 | 含义 |
| --- | --- | --- |
| clk / rst | 输入 1 / 1 | 像素时钟 / 同步复位 |
| pair_valid_i | 输入 1 | 已预留并保持稳定的 pair offer |
| pair_sync_id_i | 输入 16 | pair 的同步标识 |
| left_bank_i / right_bank_i | 输入各 1 | 两眼被选择 bank |
| bbox_valid_i | 输入 1 | 当前 RIGHT bank 的有效 bbox |
| bbox_x1_i / bbox_x2_i | 输入各 8 | RIGHT bbox 包含式水平坐标 |
| bbox_y1_i / bbox_y2_i | 输入各 7 | RIGHT bbox 包含式垂直坐标 |
| pair_accept_o | 输出 1 | 空闲时 ready=1，与 pair_valid 同拍接受 |
| pair_done_o | 输出 1 | 一拍完成/释放信号，所有拒绝路径也产生 |
| left_rd_en_o / right_rd_en_o | 输出各 1 | 一对同步读请求，READ 状态拉高 |
| left_rd_bank_o / right_rd_bank_o | 输出各 1 | 已接受 pair 的 bank 快照 |
| left_rd_addr_o / right_rd_addr_o | 输出各 14 | 0..14399 的像素线性地址 |
| left_rd_valid_i / right_rd_valid_i | 输入各 1 | 对应同步读数据有效，两侧同拍 |
| left_rd_data_i / right_rd_data_i | 输入各 8 | RAM Gray8 返回 |
| busy_o | 输出 1 | 已接受 pair，直到 DONE 周期结束 |
| range_done_o | 输出 1 | 与 pair_done 相同的一拍结果完成事件 |
| range_valid_o | 输出 1 | 最近完成结果有效性，下一次 accept/reset 清零 |
| disparity_o | 输出 6 | 有效结果 1..31；invalid 为 0 |
| distance_mm_o | 输出 16 | 距离表输出；invalid 为 0 |
| match_cost_o | 输出 13 | 搜索完成后的最小 25 点代价；未搜索/读超时为 0 |
| target_x_o / target_y_o | 输出 8 / 7 | 接受时锁存的 bbox 中心 |
| pair_sync_id_o | 输出 16 | 结果所属的已接受 sync ID |

参数默认值：FB_CONSTANT=8000（32 bit），MAX_MATCH_COST=1000（13 bit），
MIN_TEXTURE_RANGE=16（8 bit），READ_TIMEOUT_CYCLES=16。
读超时参数需为 1..65536；默认 16，正常一拍 RAM 不触发。
独立 `stereo_depth_lut` 只有 disparity_i[5:0] 输入、distance_mm_o[15:0] 输出及
32-bit FB_CONSTANT 参数。

## 5. bbox 中心

accept 时将 `(x1+x2)>>1`、`(y1+y2)>>1` 快照到 cx/cy；求和先分别扩展为 9/8 bit，
因此高坐标不会因加法位宽不足溢出。奇数和取 floor。
同时检查 bbox_valid、x1≤x2、y1≤y2、x2≤159、y2≤89。
计算开始后忽略上游 bbox、bank、sync 的变化。

RIGHT 5×5 必须满足 cx=2..157、cy=2..87；另外正视差至少 d=1，因此可实际搜索的
cx 必须 ≤156。cx=157 时模板本身可放下，但 d_max=0，直接 invalid/done。
bbox_valid=0 或坐标不合法、模板放不下、FB_CONSTANT=0 均不发任何 RAM 请求。

## 6. 5×5 模板读取

RIGHT 从 `(cx-2,cy-2)` 开始，按五行、每行五点读取；LEFT 同时读取 RIGHT 地址+d。
只计算一套中心模板，不对全图或 bbox 内其他点测距。

基地址为 `(cy-2)*160+cx-2`，160 用移位加法 128+32；每行内地址加 1，行末加
156（160-4）。只用地址/row/col 计数器，无通用乘法器。
RIGHT 不新增模板缓存，每个 d 再读同一 25 点；最多每眼 775 次读。

## 7. disparity 搜索

`d_max=min(31,157-cx)`，从 d=1 升序搜索到 d_max。一个 8-bit abs-diff 数据通路
时分使用，每次只处理一个对应 pixel，累加到一个 13-bit cost 寄存器。
没有 31×25 并行结构、cost 数组、第二最优代价、五点结果或 disparity 图像。

状态为 IDLE → CHECK → READ ↔ WAIT → EVAL → 下一候选/LOOKUP → DONE。
EVAL 仅在 25 个数据全部累加后运行；最后一个候选的更新先入寄存器，再 LOOKUP，
不会遗漏最后像素或最后 d=31。
正常 d_max=31 从接受到 DONE 为 1583 个时钟；DONE 下一边沿释放 pair。
没有对系统做布线时序验证，不将这个周期数当作已验证的板级运行频率。

## 8. 一拍 RAM 延迟

READ 状态同时拉高左右 rd_en，并保持正确地址。该边沿 RAM 采样请求，ranging
进入 WAIT；下一边沿读取 RAM 已寄存的数据和 valid，才进行 abs-diff 累加。
地址在 WAIT 保持，消费后才更新下一点，不使用组合 RAM 读。

实际 Frame RAM 返回 valid 和 data 同拍；独立 testbench 也是 posedge 同步模型。
若成对 valid 未返回，WAIT 计数到 READ_TIMEOUT_CYCLES 后输出 invalid/done，
防止接口故障永久占用 bank。两侧正常返回要求同拍；不增加独立返回重排队列。

## 9. cost 计算

`cost(d)=Σ25 |RIGHT_pixel-LEFT_pixel|`。每项 0..255，最大 6375，13 bit 足够。
best_cost 初始化 8191，best_d 初始化 0；仅 `current_cost < best_cost` 更新。
完全相同代价的候选保留先到的较小 d。本阶段不计算 SSD，也不输出整幅 SAD。

## 10. 有效性

搜索后的两项判断：best_cost≤MAX_MATCH_COST，RIGHT 模板 max_gray-min_gray
≥MIN_TEXTURE_RANGE。min/max 只在 d=1 的 25 个 RIGHT 返回中统计。
等于阈值时允许，超过 cost 或低于 texture 阈值时 invalid。

range_valid 在新 accept 时清零，完成后保持到下一 accept/reset。range_done/pair_done
是一拍事件，调试读取结果应以 range_done 标识新结果。无 bbox/边界拒绝在 accept 后
下一周期到 DONE，不等待 RAM；pair 已处于 ACTIVE，释放握手有效。

## 11. disparity→distance

31 项 LUT：每项是 elaboration 常量 `FB_CONSTANT/固定字面量 d`，floor 到整数 mm。
硬件只有 disparity 选择对应常量，不使用运行时除法器；综合测距实例 DSP=0。
d=0 和 32..63 返回 0；值超过 65535 饱和为 65535。

FB_CONSTANT=8000 时：

| d | distance_mm |
| --- | --- |
| 1 | 8000 |
| 4 | 2000 |
| 5 | 1600 |
| 8 | 1000 |
| 10 | 800 |
| 16 | 500 |
| 31 | 258 |

当前常量不是实际标定值。真实参数为采样后 160×90 图上的水平焦距（pixel）乘以
基线（mm）；不能直接用 1280 宽图的焦距代替采样后的焦距。

## 12. testbench 结果

ModelSim SE-64 2020.4，新执行 **21 个独立 testbench 全部 PASS**，各行为库 vlog/vsim
均为 0 error、0 warning。

| 阶段 | testbench | 结果 |
| --- | --- | --- |
| 6 | tb_stereo_roi_ranging | PASS，26 个场景 |
| 6 | tb_stereo_depth_lut | PASS，全部 64 个输入，4 组参数 |
| 6 | tb_stereo_roi_pair | PASS，5 个真实 Stage5 RAM/controller 集成 pair |
| 5 | tb_stereo_gray_frame_buffer | PASS |
| 5 | tb_stereo_frame_pair | PASS |
| 5 | tb_stereo_frame_pair_pipeline | PASS |
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

独立 ranging 测试使用真实一拍同步 RAM 模型、左右不同 bank 的 poison 数据，验证
七个固定 d 的正确 disparity/distance；另外检查无 bbox、低纹理、高 cost、四边及
无候选边界、有效图右下极限地址 14399、d_max 截断、ties、cost 正好 1000/1025、
texture 正好 16/15、返回超时、计算 reset、非法 bbox、上游 metadata 改变不影响快照。

静态端口、清单、时分 RTL 风格及无新图像 RAM/运行时除法器检查 PASS。
全源 vlog：A 当前清单 103 文件，0 error/80 个既有 HDMI IP 警告；B 106 文件，
1 个既有 `ph1p35_324_ddr_wrapper.v(61): Undefined variable: dhi_clk`、80 个 IP 警告。
没有把 B 全源 ModelSim 编译声称为零错误；Anlogic 原生综合对此旧隐式网络正常完成。

## 13. pair_ctrl 握手集成

实际 Stage5 controller → ranging ready/accept → ACTIVE 两眼 lock → RAM 读/计算 →
range_done/pair_done → 精确释放对应两 bank，下一 pair 可以继续。

集成 testbench 使用未修改的真实 stereo_gray_frame_buffer/stereo_pair_ctrl，验证
sync=10/d=8 的左右独立 source ID、计算期间两个备用 bank 的新写入及 ABORT、
上游新 bbox 不替换被选 RIGHT bbox；然后验证无 bbox 快速释放、反向到达 d=31、
边界 d_max=1、低纹理拒绝。共五次接受/完成，pair_count=5，无误释放或死锁。

顶层已去掉第 5 阶段常量绑值，硬件现在会自动消费和释放 pair。
range_valid、distance_mm、disparity、cost、center、result sync、busy/done 均为 keep
内部 debug wires，不连接 HDMI 或小车。

## 14. 一次综合资源

工具：Tang Dynasty V6.2.168116；器件 PH1P35MDG324、speed 3。
在全部行为测试 PASS 后，于 `simulation/stereo_stage6/b_synthesis_once/` 完成一次
实际 `elaborate → optimize_rtl → optimize_gate`，每条命令日志均只有一次。

准备阶段有两次失败：首次脚本路径的反斜杠被 Tcl 转义；第二次 native .prj 缺少
新条目的 CompileOrder，open_project 拒绝。在两次失败中都没有开始 elaborate。
修正仅作用于启动参数/独立 .prj 导出，保留失败日志；没有重复综合 B RTL。
当前 .al source entry 正式注册；仅 native .prj 中为缺省项补导出 CompileOrder。
`attempt.json` 记录 launcher_attempts=3、full_B_synthesis_runs=1、returncode=0。

来源：`b_synthesis_once/stage6_gate.area`。

| 资源 | 使用 | 可用 | 使用率 |
| --- | --- | --- | --- |
| LUT（工具 #lut） | **23660** | 报告未单列 | 不推算百分比 |
| Slice（Optimize-Gate） | **18329** | 21216 | **86.39%** |
| ERAM20K | **105** | 108 | **97.22%** |
| DSP | **17** | 40 | **42.50%** |

层级行的独立列如下，不把 logic lut、ripple 和全局 #lut 简单等同：

| 实例 | logic lut | ripple | seq | ERAM | DSP | DRAM LUT |
| --- | --- | --- | --- | --- | --- | --- |
| LEFT Frame RAM | 145 | 238 | 198 | **14** | 0 | 0 |
| RIGHT Frame RAM | 144 | 238 | 324 | **14** | 0 | 0 |
| stereo_pair_ctrl | 256 | 384 | 198 | 0 | 0 | 0 |
| stereo_roi_ranging | **151** | **106** | **171** | **0** | **0** | **0** |

四逻辑 Gray bank 实际共 **28 块 ERAM**，两侧各 14；没有推成大 LUT RAM。
这次实际映射结果替代第 5 阶段未经综合的 32 块估算；不根据块数猜测映射器内部
具体优化原因。逻辑有效缓存仍为 57600 byte，数组声明空间仍为 65536 byte。
测距实例未增加图像/cost RAM，资源中不含整图 disparity 架构。

## 15. 是否超限

综合报告所列 Slice、ERAM、DSP 均未超限，超出量均为 0；工具未报告 LUT 容量超限。
剩余 Slice=2887，ERAM=**3 块**，DSP=23。ERAM 余量很小，本阶段没有删旧 framebuffer
或做额外压缩，也没有增加后续功能。

Optimize-Gate area 自身注明 LUT/Slice 不是布局后的最终值；目前未布局/布线，
不能据此保证可布通或板级时序收敛。原生综合 0 error，144 条 warning（其中五条
RGMII IDDR 的 critical warning）；还包括旧 DDR 异步控制、ISP/旧输入未驱动警告。
ROI/depth LUT/Frame RAM/pair_ctrl 没有对应新模块 warning，RTL report 的 LATCH=0。
这些旧路径未在本阶段改动。

## 16. 已知限制和审计待办

- 距离常量未标定，8000 只证明数字换算链路；没有证明实际毫米距离准确。
- 假定 RIGHT 目标在 LEFT 的同一行、正视差方向。未做 rectification、垂直偏移
  搜索、曝光补偿、左右一致性、唯一性或亚像素；重复纹理可能仍错误通过，ties 取较小 d。
- 只取 bbox 中心一块；中心可能是背景、遮挡或混合表面，不保证代表目标整体距离。
- d=1..31、整数视差及 mm floor 限制范围/精度；d=0 不搜索，16-bit 距离饱和。
- min/max 和 cost 的默认阈值未经过真实双目采集调参。Gray8 数字一致不等于两镜头
  在曝光、镜头畸变、安装位置和采集时刻上已校准。
- 接口保证一拍成对返回；单侧独立延迟/返回不重排。超时释放 invalid。
- 系统 reset 同时清 ranging 和 pair_ctrl/Frame RAM；只复位消费者不会替 controller
  释放既有锁，单独连接时需保持一致复位策略。
- B 原有 ModelSim `dhi_clk` 静态问题保留；原生综合能处理该旧隐式网络，不表示
  本阶段修改/修复了 DDR RTL。
- 未运行 place/route/timing closure/bitgen/download，资源余量与硬件稳定性仍需以后验证。
- **A 的清单又出现外部回退，当前 `A_manifest_drift.json` 为 REVIEW_REQUIRED。**
  A RTL/约束/测试源未变，本阶段没有写 A；丢失的五个 source entry 是 stereo_sync_rx、
  stereo_frame_selector、stereo_page_metadata、stereo_metadata_mailbox、stereo_metadata_fifo。
  已在 B 的阶段目录保存观察文件和可审阅的 `A_manifest_proposed_restore.txt`。
  补回后的副本 SHA256=d3695b1e772925f8c5493f0478662edcfbc58c437681b3b0d098e0dc2534419f，
  精确匹配阶段开始和第 3.5 阶段已确认值；没有擅自把该副本写回 A。
  全部 A 协议回归使用实际 HDL 显式编译，因此通过回归不代表当前 A GUI 清单已完整。

证据和入口：`results.json`、`changes.json`、`resource_summary.json`、
`A_manifest_drift.json`、`B_manifest_drift.json` 及各 simulator/native 日志。
行为回归在阶段目录运行 `python run_stereo_stage6.py`；一次综合入口在完成后拒绝再次运行。
若之后恢复 A 清单，需要更新当前漂移状态后再审计，不应继续使用旧观察哈希。

第 6 阶段到此停止，不继续 HDMI 显示或小车控制。
