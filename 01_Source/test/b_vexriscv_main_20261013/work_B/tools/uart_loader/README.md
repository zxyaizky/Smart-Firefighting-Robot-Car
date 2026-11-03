# B 板串口下载工具

使用本轮重新生成的 bit，原来的串口自检 bit 不识别下载命令。
本轮只完成代码、仿真和 TD 静态展开，没有替你运行综合/布局/布线或生成 bit。
工程入口为 ../../td_project/camera_to_dsi_display_uart.al。

先在 TD 完整重建并下载该工程。连接板载 USB 串口，115200、8N1、无流控，
按复位并确认 VexRiscv BOOT / DDR32 PASS。然后关闭串口助手，释放 COM15。

双击 run_demo.cmd，输入实际 COM 口，默认 COM15。
它调用本机 D:\anaconda\python.exe，发送 examples/ddr_uart_hello.bin 并显示输出。
也可在 PowerShell 中运行（路径有空格时用引号）：

    D:\anaconda\python.exe .\upload.py .\examples\ddr_uart_hello.bin --port COM15 --monitor

正常输出应包含：

    DDR CRC verified; CPU is jumping to the uploaded program.
    DOWNLOADED PROGRAM OK

看到第二行，表示运行的是电脑通过串口下载的程序，不是 ROM 固定打印。
演示程序检查自身尾部哨兵、写结果寄存器 0xf0001020=C0DE0001，
并继续增加原 CPU/DDR 心跳。Ctrl+C 关闭电脑串口；CPU 仍运行演示程序。
下载后 h/s 不再由 ROM 处理；再次下载前按板上复位键，等待原自检通过。

## 发送自己的程序

只接受 raw RV32 .bin，不接受 ELF、Intel HEX、压缩内核包或任意地址的程序。
程序必须按链接地址编译；工具不会重定位二进制。例如：

    D:\anaconda\python.exe .\upload.py .\my_program.bin --port COM15 --address 0x40100000 --entry 0x40100000 --monitor

默认装载/入口均为 0x40100000。可写范围为 CPU 地址
0x40010000..0x41ffefff（对应物理 DDR 0x02010000..0x03ffefff）。
前 64 KiB 保留给原自检及缓存置换，顶部 4 KiB 保留给栈；
不会写原视频 DDR 分区。装载地址、入口均须 4 字节对齐，
长度至少 4 B，入口完整一条指令必须位于文件内；文件末尾可以不是整字。

跳转前关闭 M 中断、SATP=0、SFENCE.VMA、FENCE.I；在 M 模式进入入口，
sp=0x41fffff0，a0=0（单核 hartid），a1=0（尚无 DTB），ra=0，无返回 ABI。
程序要自带启动代码/运行环境，按需设置 trap、bss、栈、CSR 等。
UART 使用 LiteUART 轮询寄存器，尚无 UART IRQ。当前不是 Linux/SBI 引导器。
未来需要单独准备 SBI、设备树和 Linux 镜像布局；不应现在直接发送 Linux 内核。

## 协议 v1

工具自动发送小写 l。CPU 回复 VRDL READY 加 CR LF，再接收二进制协议。
不要用串口助手把 bin 当文本发送；l 只是下载入口，后面必须由工具完成握手。

24 B 小端头：magic=VRD1、装载地址 u32、长度 u32、入口 u32、
整图 CRC32 u32、前 20 B 的 CRC32 u32。头检查通过回 K。
每包 min(64,剩余长度) 字节数据，加 4 B 数据 CRC32；CPU 收齐并校验后才写 DDR，
等待前序写完成且错误寄存器为零后回 K。最后一包同样先回 K。
CPU 用保留区替换全部 32 条 Dcache 索引，再从 DDR 回读整个镜像计算 CRC32，
检查总 CRC 和 DDR 错误；通过后回 V，等待 UART 发完，执行 FENCE.I 并跳转。
CRC 为 CRC32/ISO-HDLC（反射多项式 EDB88320，初值/最终异或 FFFFFFFF），与 zlib.crc32 一致。
这是传输错误检测，未提供镜像签名验证。

错误字节：H 头/magic 校验；R 地址/长度/入口范围；C 包或 DDR 回读 CRC；
T 接收字节间超时；U 帧错误/接收溢出；E DDR 异常或下载后程序异常。
收包阶段每字节超时 2 秒（50 MHz 下 100000000 周期）。
任何错误或 ACK 不明确都立即停止，不自动重发；复位并重新开始。
不完整数据可能已存在专用 DDR 中，但没有校验成功就不会跳转。

## 依赖和限制

vendor/ 附带 pyserial 3.5 及其许可证，仅供本目录工具使用，没有修改全局 Python。
requirements.txt 可用于其他 Python 环境。API 依据：
https://pyserial.readthedocs.io/en/latest/pyserial_api.html 。
make_demo.py 可独立重新生成示例二进制及指令清单；不需要安装 RISC-V GCC。
示例仅演示 M 模式 raw binary，不是可移植应用 ABI。

115200 下每 MiB 仅线路传输的理想下限约 91 秒；实际还包含包 ACK、USB 延迟、
DDR 写入和软件 CRC，所以较大的 Linux 镜像会慢。本轮不改变 UART 时钟/速率。
板上实际串口下载、视频保持和程序执行需要你重建新 bit 后验证。
完整仿真和范围审计在 ../../reports/uart_loader_20261019/README.md。
