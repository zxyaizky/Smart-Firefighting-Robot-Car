# B板Linux云图与救援联动

**2026-10-31恢复显示算法：C7循环原图（绿点修复）→均衡化灰度→3×3中值→Sobel＋NMS→六级卡通→运动区域→帧差。B4高电平选择B板本地视频。** 见[DISPLAY_EFFECTS.md](DISPLAY_EFFECTS.md)。197份RTL编译、显示像素参考及TD层次展开通过；尚未重新综合布线或生成bit。

**2026-10-30当前源码：黄色代表火焰，语音发送`AA 55 01 55 AA`，绿色03、人员04；02障碍物提示删除。**

正式工程：`C:/Users/lx292/Desktop/qiansai_last/test/b_vexriscv_main_20261013/work_B/td_project/camera_to_dsi_display_lidar.al`。

按用户确认删除红色识别/红框、黄色绕行、普通超声波停车避障。保留绿色抓取完整任务、人员有效新鲜距离≤350 mm停车、黄色最近有效距离≤450 mm瞄准喷水、语音、测距/血氧显示，以及Linux云图、以太网视频和B4视频源切换。绿色V≥70；黄色连续10帧、绿色连续2帧确认，两类存在标志独立，5帧未检出清除。完整规则和接线见[RESCUE_INTEGRATION.md](RESCUE_INTEGRATION.md)。

黄色瞄准角度命令稳定2秒、再3次确认，最多喷水10秒；严格黄色目标一个阴性帧/视频故障/5秒无结果即撤销，连续3秒无目标重新允许喷水。后续无效测距保留最近有效距离许可。水泵输出为**J1第37脚 / GPIOA_32 / A5**；舵机U1；语音TX为P6 / J1第14脚。

绿色完成抓取回位后：后退至有效距离≥550 mm → 右转3150 ms → 直行5秒 → 左转3150 ms → 正常前进。定时段不受距离控制；E11仍可取消。其他无任务时开启E11就前进。

当前只完成源码和RTL仿真验证，**需要重新综合、布局布线并生成bit**；未生成或下载本次bit。旧B10版本物理760.583秒、综合加物理1000.747秒，setup +0.112 ns、hold +0.020 ns，属于历史结果，不能作为新源码验收。原生构建策略及CPU软分组保留，无额外末端修复脚本；`build_rescue_30min.cmd`保留历史文件名。

云图保留201×201、HDMI x=1063..1263 / y=240..440，白点、绿机器人、黄色朝向。识别只给已有点着色，不在雷达图加名称或框；颜色识别改用独立黄绿结果，红色旧寄存器槽始终无效。人员元数据保留。前视匹配仍假设60°视场，无相机/雷达标定，保留`APPROX`提示；多个前方目标可能关联错误。

Linux/Flash载荷、ESP、发送脚本、CPU和视频DDR通路保留。MMIO仍为0xf0020000，不占原CLINT的0xf0010000。接口兼容，不需要本次重编Linux。备份和验证见`reports/yellow_fire_align_20261030_210243`。

## 你接下来怎么操作

1. 重新打开磁盘上的lidar工程，使用已登记的 `rescue_route_locality.adc` 和保存的策略，从Read Design重新综合、布局布线，再生成bit。不要沿用旧网表；20分钟是本机实测目标，不保证不同机器或修改后的耗时。
2. 得到 `td_project/camera_to_dsi_display_lidar_Runs/best_result/camera_to_dsi_display_lidar.bit` 后，双击本目录 **`merge_flash.cmd`**。它只合并文件，不烧录。若 TD 输出位置不同，在 PowerShell 执行 `python pack_flash.py --bit "新 lidar bit 的完整路径"`。
3. 合并校验成功后，输出是本目录 **`build/u33_lidar_linux.bit`**。你自行使用 BitWriter 将这个完整合并镜像烧入 B 板 U33，然后重新上电。ESP32 保持现有已验证固件。不要把 `linux_flash_package.bin` 当作完整 FPGA 配置烧录。
4. 等 Linux 启动，USB 控制台执行 `uname -a`，应包含 **`-anlu-b-wifi-lidarmap`**；执行 `ls -l /dev/mem` 应存在。确认 PPP、SSH 正常。新地图 bit 和新内核必须配套，旧 bit 没有地图 MMIO。
5. Windows 连接 **Anlu-B-Linux**，关闭占用 COM22 的 L150/采集软件，双击本目录 **`send_map.cmd`**。输入 COM22，默认测试 60 秒。COM15 控制台可保持打开。SSH 登录期间不要切网、复位或断电。
6. 视频右侧中部 X=1063..1263、Y=240..440 出现地图：白色点云、绿色机器人、黄色朝向端点。5 cm/格；X 向右、Y 向上。地图按完整视频帧切换，约 2 秒无新地图时边框变红，保留最后一帧。

没有蓝牙时可先回放已验证文件（不是实时验收）：

```powershell
cd C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B\firmware\linux_wifi\lidar_hdmi
python send_map.py --replay C:\Users\lx292\Desktop\safety_grid_v1\lidar_10frames.bin --seconds 60
```

持续接收用 `python send_map.py --port COM22 --seconds 0`，Ctrl+C 结束。最高 5 FPS，单帧在途、一个最新帧等待槽，网络慢时替换旧帧，不积压。之前纯接收实测约 1.98 FPS；本显示版本的实板帧率待测，不能称为已达到 5 FPS。原 SSH 私钥和严格主机密钥校验继续使用，目标为经 ESP 路由的 **192.168.11.2:2222**。

若先试 SRAM 而不改 Flash：下载新的 lidar bit 到 SRAM，保持供电，关闭其它 COM15 读取窗口，运行本目录 `upload_kernel.cmd`，按提示在打开 COM 后复位一次，等待上传、CRC、Linux 启动完成。它仅写 DDR；约 7.49 MB 的串口上传仍需较长时间。之后再运行 `send_map.cmd`。断电会丢失 SRAM 配置和 DDR 候选。

## 设计范围

Linux 解析原 AA55/0x02 帧，将当前帧点云转换为 1 bit 位图，CPU 向新 MMIO 外设写入；不改 STM32 协议、不搬整幅视频进 Linux、不占用视频 DDR 带宽。每帧完整写 2048 个字，再提交，像素域只在 VS 帧边界交换前后页。当前仅显示收到的点及位姿，不包含 L150 软件的历史累积、SLAM 或路径规划。

CPU 时钟 `I_sys_clk` 50 MHz、复位 `S_cpu_rst`；像素时钟 `S_hdmi_pixel_clk` 75 MHz、复位来自原锁定/复位信号。Wishbone 地址来自真实 VexRiscv 数据总线，原指令、DDR、UART、timer 通路保留。顶层实例 `u_lidar_map`，CPU 实例仍为 `u_vexriscv_linux`。最终选中的 RGB/DE/VS 一起延迟一个像素周期，送入原 `u_hdmi_tx`，原 OSD 在地图矩形之外保持原数据。

两页各 2048×32，合计 **16 KiB 逻辑存储**，256 bit 行跨度，其中 201×201 可见。使用同步读、独立读写时钟 RAM 推断，无 RAM 复位或初始化文件依赖。理论按 512×32 配置约需 8 个 ERAM20K，实际映射必须看 TD 综合结果；不能将这个估算作为资源统计。

跨域使用 request/ack toggle + 两级同步器；位姿在整个待确认期间保持稳定。地图与检测快照共 6 个同步器首级设例外，稳定数据束跨域限最大延迟 10 ns；没有新增整片异步时钟豁免。综合后须检查这些约束实际命中和时序。

## MMIO 与寄存器

基地址 **0xf0020000**，下面是字节偏移。`0xf0010000..0xf001ffff` 保留给 CLINT。只允许完整 32 bit 访问；非法地址、部分写、忙时写和未完整填页即提交返回 ERR。ACK/ERR 寄存输出，读 bitmap 未开放。

|偏移|含义|
|---|---|
|0x00|ID，0x4c4d4150|
|0x04|STATUS：bit0 ready，bit1 显示有效，bit2 等待换页；bits27:16 已写字数|
|0x08|CONTROL：写 3 提交并使能；写 1 提交并关闭地图|
|0x0c|机器人：bits7:0 x，bits15:8 y，均 0..200|
|0x10|朝向端点，同上|
|0x14|FRAME_ID|
|0x18|DISPLAYED_ID，CPU 收到像素域换页确认后更新|
|0x1c|CAP，当前语义版本 0x000200c9|
|0x20..0x2c|人体/保留红槽/绿/黄临时标记（红槽无有效检测）；bit31=本帧续期，bits23:16=检测年龄（视频帧），bits15:8=y、bits7:0=x；随地图提交生效|
|0x30|写 1 请求检测快照；读 bit0=快照就绪，bit1=完成 toggle|
|0x40..0x6f|四槽一致检测快照（原红槽始终无效），每类 3 个字：STATUS、MIN、MAX；STATUS bits31:16=序号、bits15:8=年龄、bit0=有效且未过期；MIN/MAX 为 y<<16 \| x|
|0x2000..0x3fff|后页 2048 字；必须从低到高连续全部写入|

`map_io.h` 使用 RV32 mmap2 的页单位偏移 0xf0020，并检查 ID、容量、换页超时、displayed ID。每一帧的 SSH ACK 在该帧换页得到确认后才产生；这能证明外设换页握手，不能替代实际 HDMI 目视检查。

当前语义版本的 CAP 为 `0x000200c9`（原纯点云版本为 `0x000100c9`）。人体检测按原始以太网 source/result ID 去重，独立于 HDMI 本地/网络视频切换，不会靠重复显示旧视频帧延长标记。识别数据与位置通过各自的 request/ack mailbox 跨时钟传递；新增同步器首级及稳定数据束约束已列入 `constraints/lidar_map.sdc`。

朝向按 STM32 实际 `NAV/nav.c` 551..565 行的 PC 网格变换：网格 X=-算法 Y、网格 Y=算法 X，yaw 不变，因此方向 dx=-sin(yaw)、dy=cos(yaw)。屏幕显示翻转 Y。不是凭字段名称假设坐标。

## Linux 候选与回退

独立内核版本 `6.12.58-anlu-b-wifi-lidarmap`，rootfs 与已验收 auth900 版本逐字节相同。开启 CONFIG_DEVMEM、CONFIG_STRICT_DEVMEM，CONFIG_IO_STRICT_DEVMEM 关闭以允许非 RAM 外设；STRICT 保留原 EXCLUSIVE_SYSTEM_RAM 保护。其余变化仅 LOCALVERSION 和相同 rootfs 的构建路径，不改 ISA、MMU、CSR、PPP、UART 或 timer 功能。

`build/linux_uart.bin` 为 SBI+内核串口镜像，`build/linux_flash_package.bin` 为带 VRD1/CRC 的 Flash Linux 载荷。合并布局保留 FPGA 0、Linux 0x200000、MCU 0xe00000，16 MiB Flash 容量校验已通过。当前语义接收显示程序 6116 B，通过 SSH 临时部署到 `/tmp`，没有重编 rootfs。

回退完整旧镜像仍在：
`C:/Users/lx292/Desktop/qiansai_last/test/b_vexriscv_main_20261013/work_B/firmware/linux_wifi/tx_guard_20261025/build/u33_wifi_linux_txguard_auth900.bit`。
原项目 `td_project/camera_to_dsi_display_wifi_flash.al` 和原 FPGA RTL 均保留。

## 已完成验证与限制

|检查|结果及范围|
|---|---|
|C 栅格化|20 个真实/边界测试帧，全部位图和填充位逐位比较 PASS|
|RTL 随机页与真实点云页|两次各 8,299,505 像素、242,406 地图像素，RGB/DE/VS、换页、不撕裂、非法总线、过期边框、复位检查 PASS|
|TD Read Design|主顶层、CPU、地图、视频 DDR 等真实实例以及新 CDC 端点检查 PASS|
|优化前后对照|相同语义输入各 96 项检查 PASS，着色与超时恢复整幅 201×201 地图像素一致|
|布线优化与关闭抓取核|独立完整综合、布局布线和最终 setup/hold PASS；无 ChipWatcher/debug hub，Slice 90.54%；完整物理阶段 8 分 44 秒|
|QEMU 32 MiB|生产 Image 启动/用户态/MMU/timer/TCP/UDP PASS，free 20888 KiB（虚拟平台数据）|
|QEMU PPP/SSH|隔离测试内核 LCP/IPCP、双向 Ping、严格密钥 SSH、PTY PASS；非无线实板|
|/dev/mem|候选内核 RV32 mmap2、非 RAM UART scratch 读写恢复、错误 ID 拒绝 PASS|
|待做|当前语义版需生成新 bit，并验收真实识别→近似关联→地图着色、连续传输及复位/断电重启|

QEMU 不含 FPGA 0xf0020000 地图外设；直接访问会 fault。没有将此测试伪装成 Linux 与新 RTL 联合仿真。专项探针只在 QEMU UART 上验证 MMIO API，错误 ID 测试只更换测试地址，不修改正式程序。

验证报告：`C:/Users/lx292/Desktop/qiansai_last/test/b_vexriscv_main_20261013/work_B/reports/lidar_hdmi_20261025/README.md`。其中 `sim/lidar_map_rtl_preview.png` 是实际 RTL 像素仿真图，不是实板照片。

复现本地检查：`python build_display.py` → `python test_raster.py` → `python sim/run.py` → `python check_td.py` → `python audit.py`。独立内核构建输入及方法保存于 `guest_kernel.sh`、`fetch_kernel.py`、`test_kernel.py`、`test_devmem.py`；依赖现有本地 QEMU Alpine 构建环境和缓存，不下载替换原工程。
