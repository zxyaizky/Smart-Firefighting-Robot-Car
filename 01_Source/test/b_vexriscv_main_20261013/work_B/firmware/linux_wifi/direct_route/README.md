# ESP AP → PPP 直连 SSH 候选版（2026-10-25）

本目录提供绕过 ESP 用户态双 TCP 代理的候选方案。当前 B 板的 auth900 Linux、FPGA 配置、U33 Flash、视频和 DDR 均不用更换。只更新 ESP32-C3；尚未完成实板验收，不能保证它消除底层 PPP 丢包或 CPU 执行缓慢。

**当前生成和已烧录的 ESP 是 PEER_ONLY_V7_WIRE_PREFIX 诊断版，实板 PPP 仍未通过。B 板正式 UART RTL 已加入一拍 TX 预取防护，但尚未生成或下载新 FPGA bit。先阅读 `work_B/reports/linux_wifi_20261025/direct_route/uart_fifo_mapping/README.md`；其中有当前证据、仿真、备份及用户重新构建步骤。**

以下 V2 路由修复说明及旧软件测试保留作历史证据；不能作为 V7 或新 FPGA 防护的实板通过记录。旧版把优先级更高的 PPP 自动选为默认出口，会把电脑其它目的地的流量也送入 UART；现在固定 AP 为默认接口，Linux 点到点对端仍匹配 PPP 专用路由。其它目的地返回同一 AP 时由 lwIP 原有同接口转发保护丢弃。此热点用于访问 B 板，不提供互联网出口。

实测累计 IP 接收 19651 包、地址错误 19424 包；另一次电脑未接入热点时，Linux→ESP Ping 仍丢 25%，所以默认出口缺陷并非全部丢包的唯一原因。V2 每 10 秒新增一行 `LINK_RX_DIAG rx=... bad_fcs=... bad_len=... drop=... memerr=... (16-bit)`；不打印报文内容。计数在 lwIP 线程读取，使用已有 FreeRTOS 定时器，不另建采样任务或 FPGA 调试 RAM。在当前 SDK，link.chkerr 的源码递增点位于 PPP 接收 FCS 校验失败分支；若 bad_fcs 随 Ping 增长，说明 ESP 收到的 B→ESP PPP 帧损坏。计数为 16 位，长期运行会回绕；零值不保证其它方向无丢包。

## 用户操作

1. 两块板保持供电。关闭占用 ESP COM19 的监视窗口（新采集器按 Ctrl+C）；B 板 COM15 窗口可以保留。
2. 双击本目录 `flash_esp_direct.cmd`，选择 ESP 的 COM19，确认 `ESP_DIRECT_FLASH_RC=0`。此脚本只写 ESP，绝不写 B 板 U33。
3. 打开上级目录 `monitor_esp_capture.cmd`，选择 COM19。电脑连接原热点 `Anlu-B-Linux`，密码不变。等待 `PPP_UP` 和 `DIRECT_NAPT_READY: Windows -> 192.168.11.2:2222 via AP 192.168.4.1 [PEER_ONLY_V7_WIRE_PREFIX]`。连接热点时也会重新打印后者，不必为了补看日志复位 B 板。
4. 双击本目录 `check_direct.cmd`，测试结束前一直保持该热点、供电和接线。脚本会核对 Windows 到 Linux 的下一跳为 `192.168.4.1`；若不是，它会停止并保存路由证据，不会修改电脑路由。
5. 验收必须同时出现 `SSH_EXIT_CODE=0`、正确的 `riscv32` 系统版本、`ANLU_WIRELESS_SSH_PASS` 和 `WIRELESS_DIRECT_SSH_RC=0`。仅有 TCP/banner、uname 或 free 的部分输出都不算通过。
6. 通过后使用本目录 `ssh_direct.cmd` 交互登录。切网会中断 SSH；先输入 `exit` 再切网。

若 Ping 或 SSH 不稳定，先完全退出电脑 VPN/代理软件，再运行本目录 `check_link.cmd`。它会同时 Ping ESP 与 Linux，保存带时间的 CSV 及丢包统计；只做 ICMP 检查，不复位、不烧录、不修改路由。不要启动 SSH 干扰这轮对照。只有 Linux 丢包时再检查 PPP/UART/NAPT/Linux；两边都丢包时先查 Wi-Fi/电脑/AP。它不是 SSH 验收，结果为零退出码只表示诊断执行完成。

新路径地址是 **192.168.11.2:2222**。旧的 `check_wireless.cmd` 和 `192.168.4.1:2222` 仍走旧代理，不用于本次直连验收。不要同时启动多个 SSH 测试。

失败时保留 ESP 串口日志及 `work_B/reports/linux_wifi_YYYYMMDD/check_direct_*`，并在 B 板 USB 控制台逐条读取 `/tmp/wifi-start.log`、`/tmp/pppd.log`。不要为了发消息提前切网。

## 路径及接线

Windows `.4.2` → Wi-Fi AP/网关 `.4.1` → ESP IP 转发与源 NAT → PPP `.11.1` → Linux `.11.2:2222`。SSH TCP 连接由 Windows 和 Linux 直接终结，ESP 不再为本路径建立第二条 TCP 连接。SNAT 让 Linux 回包经已有 PPP 对端路由返回，不必添加 Linux 默认路由。

ESP GPIO4 TX → B J1-9/R3 RX；B J1-8/R5 TX → ESP GPIO5 RX；共地。UART 保持 115200 8N1、3.3V 逻辑，调试 USB 串口独立。

使用本地 ESP-IDF v5.5.6、既有 eppp_link 1.1.6。开启 `LWIP_IP_FORWARD`、`LWIP_IPV4_NAPT`，关闭 PPP VJ 压缩（Linux 原本配置 `novj`）。NAPT 在 AP 与 PPP 首次就绪后仅初始化一次；原 SSH 代理、熵服务和私有热点配置原样保留。NAPT 使用 SDK 默认超时，不再引入用户态 relay 的独立 TCP 生命周期。

## 已完成的软件验证

- ESP32-C3 固件编译成功；离线 esptool 镜像校验通过。V2 应用 850896 字节，具体 SHA/烧写偏移见报告 `peer_only/manifest.json`。
- `test_peer_route.py` 提取本机 IDF 真实 `ip4_route` C 函数，在隔离 VM 内使用已有 Zig 编译器验证旧默认路由错误、修复后 Linux 对端路径、无关目的地、PPP down/up 和接口枚举顺序。接口状态是测试桩；不是 ESP 全栈或射频验证。
- 真实 PPP LCP/IPCP、双向 ping、严格主机公钥校验、SSH 公钥认证、远程 uname/free 和 PTY 均通过。
- 上述路由测试运行于本地 Linux NAT 网关与 RV32 QEMU，计数器确认 DNAT/SNAT 命中，网关未监听 TCP2222。它验证“IP NAT + PPP + 当前 RV32 Linux SSH”的软件路径；**没有运行 ESP lwIP NAPT，也没有模拟 Wi-Fi 射频或真实 FPGA**。
- Windows 公共脚本的旧代理/新直连成功、失败及错误网关共五种模拟测试通过；PowerShell 语法解析通过。
- 原 ESP 源码/固件、私有热点头文件及 B 板 auth900 合并镜像哈希未变。未重新执行 TD 综合、布局布线或生成新 FPGA bit。后续已授权并执行 ESP 实板烧录；B 板 U33 始终未写入。

完整报告：`work_B/reports/linux_wifi_20261025/direct_route/peer_only/README.md`。上级报告保留 V1 的软件 NAT/SSH 测试，不能当作 V2 实板通过。

## 生成与回退

用本机 Python 执行 `prepare.py`，复用上级 `build_esp.py`、官方依赖和原代理源文件，在本目录重建；不重新下载项目。`test_nat.py` 使用既有隔离构建虚拟机进行软件回归，不能对真实 COM 使用。

回退 ESP：关闭 COM19 监视器，运行上级目录原 `flash_esp.cmd`，再使用原 `.4.1:2222` 代理脚本。B 板不需要重新烧录。公共 `ssh_windows.ps1` 修改前副本保存在报告目录 `ssh_windows.before_direct.ps1`，默认不加 `-Direct` 时仍保持原连接目标。
