# Smart Firefighting Robot Car

从 `D:/7/qiansai_last` 整理出的代码与文档，整理日期：2026-11-03。原目录及原代码未修改、未删除。

## 目录

- `01_Source/`：FPGA RTL、IP、约束、Linux/ESP 固件、上位机源码、模型参数、工具及保留的测试源码。沿用工程内部相对目录，防止 IP 和初始化文件引用失效。
- `02_Documents/`：系统框架图、绘图脚本和原工程入口说明。各模块的详细文档仍保留在对应源码目录的 `doc/` 或 README 中。
- `03_Verification/`：源文件/目标文件 SHA-256 清单、排除文件清单及工程引用核对结果。

## 正式工程入口

| 模块 | 相对本目录的入口 |
|---|---|
| A / NPU 板 | `01_Source/lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/camera_to_dsi_display.al` |
| B 板（控制、Linux、云图） | `01_Source/test/b_vexriscv_main_20261013/work_B/td_project/camera_to_dsi_display_lidar.al` |
| 以太网上位机源码 | `01_Source/ethernet_host/main.py` |
| B 板控制说明 | `01_Source/test/b_vexriscv_main_20261013/work_B/firmware/linux_wifi/lidar_hdmi/RESCUE_INTEGRATION.md` |
| 雷达云图发送器 | `01_Source/test/b_vexriscv_main_20261013/work_B/firmware/linux_wifi/lidar_hdmi/send_map.py` |

### B 板代码位置

- 顶层及救援/喷水逻辑：`01_Source/test/b_vexriscv_main_20261013/work_B/firmware/linux_wifi/lidar_hdmi/rtl/`
- 外设驱动及 CPU 模块：`01_Source/test/b_vexriscv_main_20261013/work_B/td_project/import/`
- 引脚约束：`01_Source/test/b_vexriscv_main_20261013/work_B/user_source/constraints_source/pin.adc`
- 固件与 ESP 工程：`01_Source/test/b_vexriscv_main_20261013/work_B/firmware/`
- 当前单次喷水上限：10 秒；连续无严格黄色目标 3 秒后重新允许触发。既有中止条件仍有效。
- 超声波：Trig 为 T3 / J1 第 6 脚，Echo 为 T2 / J1 第 7 脚。

## 使用

1. FPGA 工程用本机 TD 打开上表中对应的 `.al`；目标副本的 TD 工程根目录已更新，RTL 内容保持原样。
2. 上位机需要 Python 与 PyQt5：在 `01_Source/ethernet_host/` 执行 `python -m pip install -r requirements.txt`，然后执行 `python main.py`，也可双击该目录的 `启动上位机.cmd`。
3. 云图和 B 板串口入口位于 `01_Source/雷达云图持续传输.cmd` 与 `01_Source/B板Linux串口.cmd`。原脚本继续使用 `D:/anaconda/python.exe`；更换电脑时需配置 Python 和串口。ESP/Linux 重建还需原项目对应的外部工具链。
4. 此次仅整理代码和文件，未重新生成 bit、固件或操作硬件。固件目录中保留的镜像属于原有配套文件，不代表本次源码的新构建结果。

## 历史参考

- `01_Source/test/lab_ex3_osd_SC500_720P/`：保留的原版 B 板参考工程。
- `01_Source/test8_udp_legacy_diag/`：旧以太网诊断工程。
- `01_Source/lab_ex3_osd_SC500_720/lab_ex3_osd/flash/` 中的版本目录为原有模型参数、脚本和资料；正式工程以 `.al` 实际登记文件为准。

## 整理和校验

共复制 3093 个文件，约 187.2 MiB；逐文件核对哈希，并确认 4 个 TD 工程的 720 条文件引用全部存在。

已过滤 Git 对象、TD 综合布线缓存、ESP 编译缓存、日志、上位机打包依赖、历史 bit/可执行程序/压缩包、抓帧和大型仿真观测结果；工程明确登记的文件优先保留。部分仿真输入图像和抓帧数据留在原目录，需要重跑相关历史实验时从原目录取回。具体过滤项见 `03_Verification/excluded_files.csv`。

业务代码未重构、未修改。只调整目标副本 `.al` 的工程目录；修改明细在 `03_Verification/verification.json`。原目录源码哈希复核通过。此校验不等于完成综合、时序分析或实板验证。

## GitHub 源码版本

公开仓库：<https://github.com/zxyaizky/Smart-Firefighting-Robot-Car>。

GitHub 版本保留源码、模型参数、文档及 TD 工程所需的 RTL/初始化文件。设备 SSH 密钥、主机认证记录和固件构建目录中的预编译镜像不进入仓库；这些文件仍保留在本地整理目录。原始整理清单记录的是本地完整副本，GitHub 的实际文件以 Git 跟踪列表和 `.gitignore` 为准。硬件连接和固件重新构建所需的设备密钥须自行在本地配置。
