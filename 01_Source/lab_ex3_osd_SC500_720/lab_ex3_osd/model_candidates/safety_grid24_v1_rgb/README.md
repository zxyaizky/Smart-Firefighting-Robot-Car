# 训练参数导入记录（尚未启用）

2026-09-12。用户提供 `safety_grid_v1/runs/deploy/params/parameters128.hex`。
已将参数及同目录部署元数据原样复制进本目录，并验证其一致性。
当前状态：**DDR数据传输验证通过；尚未替换生产网络配置。**

## 为什么不能直接启用

用户此前明确要求保留12层网络。当前 `td_project/import/npu_model_config.vh`
仍为12层；这份部署包为24层，描述符有效192个32位字（文件共256字）。

| 项目 | 当前工程 | 新参数包 |
|---|---|---|
| 层数 | 12 | 24 |
| 第一层通道 | 3→8 | 3→16 |
| 第四层通道 | 32→64 | 32→96 |
| 第一层权重字节偏移 | 557,056 | 0 |
| 参数镜像字节数 | 619,648（测试参数） | 327,680（用户训练参数） |
| 输入 | 160×120 RGB CHW | 160×120 RGB CHW |
| 输出形状 | 20×15×9 | 20×15×9 |

当前第一条权重请求已超出新镜像长度。只换HEX而保留当前描述符，会被DDR桥的已加载长度检查拒绝。
此外，各层通道、权重/偏置偏移、移位和操作标志存在差异，完整对照见 `compatibility.json`。
不能截取前12层或修改层数标签来转换已训练模型。

继续启用需要用户明确改为本包24层模型，或提供匹配当前12层架构的训练参数及描述符。
选择24层后仍须核对描述符操作标志、量化和参数排列，并执行独立整数参考模型与RTL全网络对照。

## 本次修改清单

- 本目录新增：`parameters128.hex`、`parameters_ddr.bin`、`manifest.json`、
  `deployment.json`、`npu_desc.hex`，均与用户源文件逐文件SHA256一致。
- 新增 `sim/import_trained_candidate.py`：HEX128小端重建，核对两个二进制镜像及HEX32、
  CRC32/SHA256、输入格式、逐层描述符与参数范围/移位，并生成兼容性报告。
- 新增 `sim/run_trained_ddr.py`：真实参数通过现有RTL通用写入接口上传，
  完整CRC回读后，经NPU跨时钟桥顺序读出，Python与原二进制逐字节比较。
  使用已有DDR单元测试的握手驱动，输出独立的候选参数测试台和日志。
- 结果位于 `sim/ddr/trained_candidate/`。
- 本次未修改生产RTL、现有12层描述符、内部IP及摄像头/视频配置。

## 校验和RTL仿真结果

- 参数327,680字节，20,480个128位上传数据块；CRC32：`b5bf7d07`。
- 二进制SHA256：`da227f75e0460dda6d0e226fec3cc9e6f6ded712442defefdb15ff4f05a013bf`。
- NPU侧163,840个16位半字均经跨时钟桥读取，327,680字节全部一致，差异0。
- 并行视频读回419,763次，均核对通过；上传包含间断，native地址/数据分别受到背压。
- 覆盖先地址后数据336,012次、先数据后地址104,231次（包括视频事务）。
- ModelSim 2020.4：PASS，0 errors；8条warning来自原厂FIFO模型未使用端口及常量位宽。
- 另重跑 `sim/run_ddr.py`：PASS，2,060个半字、5,358次视频回读；
  复位、忙时重载、坏CRC/last、越界和64项返回标签队列等既有DDR回归通过。

在工程根目录 `lab_ex3_osd_SC500_720P` 下执行PowerShell：

```powershell
$env:PATH = 'D:\BaiduNetdiskDownload\win64;' + $env:PATH
D:/anaconda/python.exe lab_ex3_osd/sim/import_trained_candidate.py C:/Users/lx292/Desktop/safety_grid_v1/runs/deploy/params/parameters128.hex
D:/anaconda/python.exe lab_ex3_osd/sim/run_trained_ddr.py
D:/anaconda/python.exe lab_ex3_osd/sim/run_ddr.py
```

重新导入脚本只复制候选参数并审计，不会启用24层描述符。后续仅重跑仿真无需访问源目录。

## 未完成/未验证

- 尚未执行24层推理，未验证训练精度、真实图像检测和精确预处理采样相位。
- 本次未重跑12层全网络回归；生产计算RTL与参数配置未改动，历史回归记录保持原含义。
- 使用行为级native DDR模型，未仿真物理DDR PHY；未综合、布局布线或上板。
- 顶层仍仅预留通用上传接口，尚无串口/网口等实际参数发送端。
  将HEX复制进工程不会自动写入板上DDR，也不会自动解除NPU等待加载状态。
