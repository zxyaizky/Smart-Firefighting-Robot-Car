# B 板单核 SBI 与设备树

这是常驻 M 模式的板级 SBI 固件，基于本地 VexRiscv 官方 emulator 移植，
补充 SBI 0.2 BASE/TIME、正确的 UART RX、Sv32/S/U 时间读取与异常转交。
不是 OpenSBI；尚未用真实 Linux 内核完成启动验收。

本轮没有修改任何 RTL、TD 工程、引脚或 DDR 参数。**保持刚收到 LINUX TIMER PASS
的当前 bit 即可，不用重新综合、布局布线或生成 bit。**

## 现在进行实板验收

1. 在原定时器串口窗口按 Ctrl+C 退出，关闭串口助手，释放 COM15。
2. 保留当前 bit，按 B 板全局复位键，使原 ROM 重新完成 DDR 自检、进入加载菜单。
3. 双击 `tools/uart_loader/run_sbi_probe.cmd`，默认 COM15，回车即可。
4. 预期依次出现：

```text
DDR CRC verified; CPU is starting SBI.
VexRiscv B SBI 0.2
RX TEST>
SBI PROBE PASS
```

脚本看见 RX TEST 后自动发送一个 Z，验证 SBI 串口接收；不需手动发送。
PASS 后脚本退出并关闭 COM，CPU 继续在 S 模式递增两个原有心跳。
CPU 结果寄存器 `0xF0001020` 为 `0x5B100001`；失败为 `0xBAD52001`，
固件异常为 `0xBAD51001`。本阶段 UART 是主要验收口，不新增 ChipWatcher RAM。
再次下载前仍需全局复位。这个程序没有 Linux shell。

## 构建与文件

工作根目录：
`C:/Users/lx292/Desktop/qiansai_last/test/b_vexriscv_main_20261013/work_B`。

```powershell
D:/anaconda/python.exe firmware/vexriscv_sbi/build.py
```

| 文件 | 用途 |
| --- | --- |
| `build/sbi_probe.bin` | 当前要经串口上传的 SBI + DTB + S/U 验收程序组合 |
| `build/fw_jump.bin` | 后续 Linux 用的常驻 M 模式固件；不含内核/根文件系统 |
| `build/board.dtb`、`board.dts` | 编译后的设备树及源文件 |
| `build/probe.bin` | S/U 模式验收载荷，不是 Linux |
| `build/mock_image.bin` | 仿真中验证正式入口交接的带签名替身，不是 Linux |
| `build/*.elf/*.map/*.json` | 可调试程序、链接布局和地址/哈希 |
| `build/manifest.json` | 全部实际编译/链接命令及版本、加载地址和哈希 |
| `upstream/` | 复用的官方原始文件、许可证及 commit/文件 SHA256 |

编译器使用本目录 `toolchain/ziglang/zig.exe` 的 LLVM C/汇编后端，链接器复用
本机 Vitis 自带 `D:/BaiduNetdiskDownload/Vitis_HLS/2023.2/vcxx/libexec/ld.lld.exe`。
未安装系统软件、未修改 PATH。DTC 为经官方包 SHA256 校验的 MSYS2 1.8.1。
若移到另一台电脑，应先在 `build.py` 指定已有 LLD 的实际路径。
`fetch_tools.py` 是缺失时获取本地便携工具的脚本，已有文件哈希正确时不会重复下载。

## 固件能力与边界

| 接口 | 状态 |
| --- | --- |
| SBI BASE 全部 0..6 FID | 实现；版本报告 0.2 |
| SBI TIME `set_timer` | RV32 64 位绝对时间、清 STIP、重新设置、全 1 停止 |
| Legacy 0/1/2 | 定时器、putchar、非阻塞 getchar（空时 -1） |
| Legacy 8 | 停止 CPU，原视频硬件仍可运行；不是 FPGA 复位 |
| 未知 EID/FID | 返回 NOT_SUPPORTED(-2)，不假称成功 |
| `time/timeh` | M 模式模拟，只允许读取；保留 rd=x0、rd=sp 及寄存器上下文 |
| `scounteren` | 软件模拟读/写/置位/清位及立即数形式，仅 TM 位有效；TM=0 时 U 读时间异常 |
| Sv32 / S / U | MPRV+MXR 获取原模式指令，支持执行专用页；异常正确转交 S |
| HSM、IPI、RFENCE、SRST、PMU、DBCN | 不声明、不实现；当前 Linux 路线为单核 UP |
| cycle/instret | 未模拟，不在 DTB 中声明完整 Zicntr |
| PMP | 当前核无 PMP，不提供固件硬件隔离；以 DTB 保留区避免 Linux 分配覆盖 |

实现标识 `0x414E4C55` 是本项目未注册的本地 ID，不冒用 OpenSBI、BBL 等已分配 ID。
BASE 的 mvendorid/marchid/mimpid 返回规范允许的 0，不读取缺失的 MISA 或只写 CSR。
原 CPU 的 ISA、CSR、M/S/U、MMU、原子及乘除法配置完全不变。

## 内存和启动 ABI

| 地址 | 用途 |
| --- | --- |
| `0x40000000..0x41FFFFFF` | 已有 CPU 独享的 32 MiB DDR 窗口 |
| `0x40000000..0x401FFFFF` | DTB 中保留的固件区域，含现有自检区、SBI、栈和 DTB |
| `0x40100000` | ROM 串口加载后的 SBI 入口 |
| `0x40102000` | 本轮独立验收载荷入口 |
| `0x4010FF80` | M 模式 trap frame，M 栈向低地址增长 |
| `0x40400000` | 正式 RV32 Linux Image 的 4 MiB 对齐入口 |

正式 `fw_jump` 在内核签名缺失时输出 `LINUX IMAGE MISSING` 并停止，不跳入空 DDR。
签名检查是基本防空载检查，不是完整内核镜像认证。正式交接为 S 模式、
`a0=0`（hartid）、`a1=内嵌 DTB 实际地址`、`satp=0`、S 中断关闭。
内核 Image 必须由下一阶段加载到 0x40400000 后才能使用这个入口。

DTB 仅暴露真实 CPU 32 MiB 窗口；视频 DDR 不属于 Linux 内存。
CLINT 为 M 固件所有，Linux 通过 SBI 使用定时器；串口通过 HVC/SBI 轮询，
未虚构 UART IRQ 或 PLIC。后续内核需启用 RISCV_SBI、RISCV_SBI_V01、HVC_RISCV_SBI、
MMU，并使用 RV32IMA、无 C/F/D、单核配置。此处尚未生成内核配置或内核镜像。

## 验证范围

详见 `reports/linux_sbi_20261020/README.md`。仿真使用真实当前 CPU、CSR/MMU、
定时器、MMIO 和 115200 UART；软件单元测试由 TB 预载 Wishbone RAM、覆盖复位
向量，没有把它当成 ROM/实板启动证据。当前串口加载协议和 RTL 完全沿用已实板
验证版本，本轮未由 Codex 打开 COM15、运行 TD 或写 Flash。

下一步在本实板验收通过后构建针对当前地址图的 Linux 与最小根文件系统，先用
串口完成内核启动，再实现 Flash 镜像存储和自动加载。
