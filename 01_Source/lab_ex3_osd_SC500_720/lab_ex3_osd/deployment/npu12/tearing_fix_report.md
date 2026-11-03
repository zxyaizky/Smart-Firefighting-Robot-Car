# 720p画面撕裂修复记录

日期：2026-09-13

## 原因与修改

新增的`npu_ddr_scheduler`把视频FIFO队首先锁存到寄存器，再在下一拍发送，导致连续视频DDR命令之间固定出现一个空拍，峰值吞吐由每个DDR时钟一个命令下降为每两个时钟一个命令。720p实时读写因此可能出现输入FIFO溢出或显示FIFO读空，表现为画面撕裂和数据混乱。

现已恢复官方视频通路的时序：FIFO队首直接送到DDR原生接口，命令与写数据均就绪时出队，连续视频请求可以逐周期发送。参数加载和NPU读访问仍只在视频FIFO空闲时进入DDR，不修改摄像头、显示、NPU计算阵列、12层descriptor或量化逻辑。

修改文件：

- `td_project/import/npu_ddr_scheduler.v`
- `sim/ddr/tb_video_throughput.v`
- `sim/run_ddr.py`
- `sim/build_u33_image.py`

## 仿真结果

- `python sim/run_ddr.py`：PASS；64个有序视频写命令在64个连续DDR时钟内完成；DDR分离握手、64个读标签、复位和错误路径均通过。
- `python sim/run_u33_boot.py`：PASS；U33参数327,680字节完整写入及CRC读回，启动期间视频流继续运行，L0首两个半字可读。
- `python sim/run_video_network.py`：PASS；两帧1280×720、采样位置、57,600字节CHW打包、忙时跳帧及12层网络均通过。
- `python sim/run_ddr_network.py`：PASS；两帧1280×720、57,600字节NPU输入和12层网络联合回归通过，最终2,700个值零差异。

旧候选模型脚本`sim/run_trained_ddr.py`仍绑定`model_candidates/safety_grid24_v1_rgb`的旧配置哈希，因与当前12层部署配置不一致而在仿真前审计中停止；它不是当前`deployment/npu12`镜像的回归入口。

## 实现结果

- 新bit：`td_project/camera_to_dsi_display_Runs/best_result/camera_to_dsi_display.bit`
- 新配置bin SHA256：`8bcfa83ea99c6a7025cbeee726ede60d9d61e3badf0e59ba2fc65ef2446c6c50`
- 最终时序：Setup `+0.101 ns`，Hold `+0.020 ns`
- U33单文件镜像：`deployment/npu12/u33_flash_image.bin`
- 镜像大小：14,680,104字节（`0xE00028`）
- 镜像SHA256：`d9a5cac2302b13d38c81a673df5cef029e95a4397b857055c0be5d92b51558aa`

镜像布局已逐段核对：

- `0x000000..0x1B4CCF`：新FPGA配置bin
- `0x1B4CD0..0x1FFFFF`：`0xFF`
- `0x200000..0x24FFFF`：NPU参数
- `0x250000..0xDFFFFF`：`0xFF`
- `0xE00000..0xE00027`：硬MCU启动固件

板上效果仍需用新镜像重新烧写U33并断电重启后确认。
