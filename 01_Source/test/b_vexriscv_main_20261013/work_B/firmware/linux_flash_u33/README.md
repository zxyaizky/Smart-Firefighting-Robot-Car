# B 板 U33 Flash 自动启动候选版本

这是 B 板独立适配，A 板 NPU 不参与 B 板 Linux 启动。A 板文件只读。
已验证的 `td_project/camera_to_dsi_display_uart.al` 和它的 RTL 不修改。
新增工程为 `td_project/camera_to_dsi_display_linux_flash.al`，顶层仍为
`design_top_wrapper`，实际源文件在本目录 `build/rtl/`。

## 与 NPU 权重加载的关系

A 板实际机制是 U33 配置 Flash、硬 MCU 的 QSPI0/XIP、AHB 桥、DDR。
源代码是 A 板 `user_source/hdl_source/design_top_wrapper.v` 中的
`u_npu_flash_mcu` 和 `td_project/import/npu_u33_mcu_bridge.v`。
MCU IP 内含 `PH1P_LOGIC_QSPI2MCU`，配置结束后把专用配置 Flash 接口交给硬 MCU。
本候选复制相同 MCU IP 到 B 板自己的目录，复用同一硬件机制，无新增板外 Flash 引脚。

NPU 桥不能直接搬来：其 `expected_addr_q`、`data_addr_q` 是 19 位，
原参数只有 327680 字节，B 板 Linux 包为 5769156 字节。
B 板改为 MCU 读取 XIP，向 VexRiscv 提供只读 Flash 通道；由 VexRiscv
通过原有 Wishbone/CDC/视频优先 DDR 仲裁通路复制到 DDR。
没有增加 DDR 主设备，没有改原视频 FIFO、帧缓冲分区或 DDR 控制器。

```
B 板 U33 Flash
  → B 板硬 MCU（独立于 VexRiscv，固件在 0x20E00000 执行）
  → AHB 只读请求服务 / 同步握手
  → VexRiscv D-bus 的 0x20000000..0x20FFFFFF 窗口
  → ROM 软件复制到 DDR 0x40100000
  → 原整段 DDR CRC / FENCE.I / 跳转
  → 原 SBI → Linux → initramfs → B-linux#
```

## Flash 布局

| 内容 | Flash 偏移 | 长度 / 结束地址（不含） |
| --- | --- | --- |
| **本候选新生成的 FPGA 配置 .bin** | `0x000000` | 必须不超过 `0x200000` 字节 |
| SBI + Linux + 内置 rootfs 的原启动包 | `0x200000` | 5769156 字节，结束 `0x7807C4` |
| 新的硬 MCU 读服务固件 | `0xE00000` | 32 字节，结束 `0xE00020` |

总容量按 NPU 工程同型号 U33 的 16 MiB 设计，区域无重叠。未读取 B 板实物 JEDEC ID。
Linux 包与已由用户串口启动成功的包完全相同；CRC32 为 `bf69b324`。
现阶段长度和 CRC 编入候选 ROM，沿用 NPU 参数元数据固定在 FPGA 中的做法。
**更换 Linux 包时须重新运行 build.py 并重新构建本候选 FPGA 配置。**

## 启动与失败处理

VexRiscv 时钟、复位、ROM 0 地址入口和原 CPU/DDR 自检不变。
DDR32 自检通过后，第一次 ROM 菜单轮询自动尝试加载 Flash，仅尝试一次。
复制完成复用原 UART loader 的 D-cache 驱逐、全 DDR CRC 回读、FENCE.I、
M 模式跳转，Linux 入口仍为 `0x40100000`、内核在 `0x40400000`。
CRC 通过前不执行 Flash 里的 Linux/SBI。

Flash 内容不匹配返回 `C`；MCU 无响应导致有界 Wishbone ERR，ROM 返回 `E`。
失败后恢复原 ROM 串口菜单，仍可用 `run_linux.cmd` 串口加载。
Flash 读超时后该读桥保持错误状态，直至全局复位，防止迟到响应污染后续读。
该状态不会封锁原 UART 或 DDR 通路。

硬 MCU 与桥的 AHB 域在原有 100 MHz 时钟下运行，VexRiscv 仍为 50 MHz。
跨域使用请求/响应 toggle 两级同步、一次只处理一个请求；地址/数据在握手期间保持稳定。
两域随 CPU 复位一起复位。新增 `u33_flash.sdc` 只约束新 AHB 时钟和此跨域通路，
未修改原有视频、DDR、引脚约束；其最终应用和时序收敛须在综合后的网表中确认。

## 重现与手动构建

在 `work_B` 中运行：

```powershell
& 'D:/anaconda/python.exe' firmware/linux_flash_u33/build.py
& 'D:/anaconda/python.exe' firmware/linux_flash_u33/check.py --cpu --static
```

打开 **B 板** `td_project/camera_to_dsi_display_linux_flash.al`。
从 Read Design 开始重新综合、布局布线，随后生成该候选的原始配置 `.bin`。
不能使用先前 TIMER/SBI-PASS 的旧配置文件：旧配置中不存在此 MCU 读桥和自动启动 ROM。
本轮只执行仿真和静态展开，不替用户执行这些完整构建步骤。

取得新配置 `.bin` 后，在 `work_B` 运行：

```powershell
& 'D:/anaconda/python.exe' firmware/linux_flash_u33/pack_flash.py --bitstream '新候选配置.bin的完整路径'
```

输出 `build/u33_linux_flash_image.bin` 与 `build/combined_manifest.json`。
打包器检查区域、容量、Linux 哈希与过旧配置文件，空隙填 `0xFF`，只生成电脑文件。
时间戳不能证明配置来自哪个工程，仍须核对 TD 构建来源。
没有新候选配置时不生成可烧录的整片镜像，避免把旧 bit 与新软件误组合。
BitWriter 的实际烧录由用户核对设备为 **B 板 U33** 后操作，本脚本不执行。
这会替换 B 板的 FPGA 配置和 Flash 内容，应保留原可用镜像。

实板验收：先打开 115200 8N1 ASCII 串口，再对 B 板断电上电，不进行串口上传；
应自动出现 SBI、Linux 与 `B-linux#`，执行 `uname -a`、`free`、`uptime`；
同时确认视频、HSV、测距正常。完整上电时间、资源、路由时间均待新构建/实板验证。

## 验证边界

结果在 `reports/linux_flash_u33_20261020/checks.json` 和 `sim/*.log`。
桥测试覆盖独立时钟、AHB 地址/数据相位、超过 512 KiB 的地址、只读保护、错误、
超时、迟到响应、取消事务和复位。真实 CPU 测试覆盖正常复制/CRC/跳转、
损坏 CRC 拒绝、缺失 MCU 超时；使用 1 KiB 程序和行为 AHB/DDR 模型，具有 X 检查。
完整 5.5 MiB 包做了布局/字节检查，**尚未完整执行 Flash → Linux 的实板启动**。
MCU 32 字节固件做了实际机器码解释执行检查；未模拟厂商硬 MCU/QSPI 的电气行为。
TD 仅检查主顶层展开和真实 CPU/MCU/Flash 桥层次，未进行综合、布线、bit 生成或烧录。
