# B 板首次 Linux 串口启动

沿用已在实板输出 `LINUX TIMER PASS`、`SBI PROBE PASS` 的当前 bit。
本目录只增加软件与电脑侧构建/仿真工具，未修改 A 板、B 板 RTL、TD 工程、
引脚、视频链路、DDR 仲裁或已有 SBI 固件。不会自动打开 COM15 或烧录 FPGA。

## 实板运行

1. 关闭串口助手和旧串口脚本，释放 COM15。
2. 保持当前 bit，运行 `tools/uart_loader/run_linux.cmd`，COM15 回车。
3. 出现 `COM opened. NOW press ... GLOBAL RESET` 后，再按 B 板全局复位键。
   脚本最多等待 120 秒，只有收到 `DDR32 PASS` 和 ROM 菜单才发送加载命令。
4. 等待整个启动包上传、DDR CRC 校验和内核启动。`Sent ... (100%)` 只表示分包已接收，
   此后还要等待整段 DDR CRC。当前包的校验超时约 115 秒，这是脚本等待上限，并非实板测得的耗时。
   不要按 Ctrl+C 或复位，直到出现 `DDR CRC verified` 和后续启动输出。
5. 出现 `LINUX UMODE MMU UNALIGNED TIMER PASS`、`ANLU LINUX USERSPACE READY`
   和 `B-linux# ` 后输入：

```sh
uname -a
free
cat /proc/cpuinfo
uptime
```

成功标准：内核版本含 `6.12.58-anlu-b`、架构 `riscv32`，有内存统计、
CPU 信息和持续增长的 uptime，输入命令后能返回 shell 提示符，原视频继续正常。
**串口上传完成、DDR CRC 或 SBI banner 单独出现均不足以证明 Linux 成功。**

115200 8N1 传输需要数分钟，精确大小与理论最短耗时见 `build/manifest.json`。
沿用已验证 ROM 的单段上传协议，SBI 与内核之间的 3 MiB 地址填充也需要传输；
实际还包括分包 ACK 和 DDR 回读时间。不要在等待过程中重发或复位。
若上传失败，保留日志、全局复位，再重新运行。

若已到 100% 后按了 Ctrl+C，先保持板子供电，不要复位。运行
`tools/uart_loader/monitor_linux.cmd`，选择 COM15；它只重连终端，不发送加载命令，
也不要求重新上传。若启动输出已经错过，可手动按一次回车尝试获取 shell 提示符。
重连日志追加到 `board_console_latest.log`；关闭串口期间丢失的输出无法追回。
能重连不代表 CRC 或 Linux 启动已通过，仍需检查下面列出的成功标准。

脚本自带简单终端，输入会回显；Ctrl+C 关闭电脑端串口。脚本将输出保存到
`reports/linux_boot_20261020/board_console_latest.log`。
复位/自检阶段的原始串口输出保存在同目录 `board_loader_latest.log`。
若没有任何串口数据或只有旧程序输出，脚本会停止，不能据此直接断言 bit 版本错误。
当前 UART RX FIFO 为 16 字节，SBI hvc0 使用轮询，终端限制了输入速度。
不要同时用串口助手打开 COM15。现有 DTB 的 `keep_bootcon` 可能使部分内核行显示两遍。

## 实际内容与地址

| 内容 | 地址或配置 |
| --- | --- |
| 当前 FPGA | 仍是 TIMER/SBI-PASS bit，无重新综合/布线 |
| CPU DDR 窗口 | `0x40000000..0x41FFFFFF`，不含视频 DDR |
| 既有 SBI + 内嵌 DTB | `0x40100000`，原 `fw_jump.bin` 完全不变 |
| Linux Image + 内嵌根文件系统 | `0x40400000` |
| 内核 | Linux 6.12.58，S 模式、RV32IMA、Sv32、单核，无 C/F/D/V |
| 用户态 | BusyBox 1.36.1 + musl 1.2.5，静态 RV32 ilp32 |
| 控制台 | 现有 USB UART，经 legacy SBI 轮询到 `hvc0` |
| 定时器 | 当前 bit 的 50 MHz 定时器，经 SBI TIME 到 S 模式 |
| 根文件系统 | 内嵌 gzip cpio，RAM 中运行，有 init、ash、基本命令与用户态自检 |

生成的 `build/Image` 已包含根文件系统，无需再单独上传 rootfs。
`build/linux_uart.bin` 为当前 ROM 可直接加载的组合包；上传前脚本核对大小、
SHA256、地址范围。`build/manifest.json` 记录内核头、ELF ABI、各文件哈希及大小。
`vmlinux` 为调试 ELF，不能直接送给 ROM 加载器。

当前用于首次串口启动验证，没有网络、SSH、Flash 自动加载、Linux 视频设备驱动。
原视频由 FPGA 硬件继续处理；Linux 尚不能通过设备驱动控制它。
RAM 中的文件和软件在复位/断电后丢失。先完成此次实板验收，再做 Flash 读控制器、
镜像布局与自动加载；不会因此擦写 FPGA 配置 Flash。

## 构建与检查

在 `work_B` 中使用 `D:/anaconda/python.exe`。

`fetch.py` 获取固定版本输入并核对哈希，已有正确文件不重复下载；`fetch_apk.py`
缓存便携构建主机的依赖。`builder.py` 启动无窗口 QEMU Linux 构建机，独立磁盘为
`cache/builder.qcow2`。未安装 WSL、未修改 Windows PATH、未接触主机物理磁盘。
`guest_prepare.sh` 只在此虚拟机内使用 `/dev/vda`；不要在其他 Linux 主机直接执行它。

`guest_build.sh` 是实际构建方法：LLVM/Clang 构建 RV32 musl、BusyBox 和内核；
`rv32_cc.py` 指向真实 musl CRT 与 RV32 compiler helpers，避免误链接 x86 运行库。
Zig 0.13 仅提供 freestanding compiler helpers，不使用其缺失的 RV32 Linux libc。
BusyBox 使用 `CONFIG_LFS=y` 匹配 musl 的 64 位文件偏移；内核直接嵌入已生成的
`rootfs.cpio.gz`，避免精简构建主机的 find/date 命令影响根文件系统打包。
`send_artifacts.py` 使用二进制 HTTP 传输；BusyBox wget 的文本 POST 不用于二进制产物。

`pack.py` 检查真实 Linux Image 头、4 MiB 偏移、包含 BSS 的大小、RV32 ELF ABI、
静态链接和内核必需选项，再生成组合包。构建版本和最终验证见报告目录。
QEMU 的 virt 平台启动使用自己的 OpenSBI/设备树，只验证 Linux/根文件系统；
板级 SBI 和当前 CPU 的验证另用真实 RTL 与预载 Wishbone RAM，不冒充 DDR PHY 仿真。

参考：[RISC-V 启动 ABI](https://docs.kernel.org/arch/riscv/boot.html)、
[Linux 6.6 SBI hvc 驱动](https://github.com/torvalds/linux/blob/v6.6/drivers/tty/hvc/hvc_riscv_sbi.c)、
[musl 构建说明](https://wiki.musl-libc.org/getting-started.html)。
