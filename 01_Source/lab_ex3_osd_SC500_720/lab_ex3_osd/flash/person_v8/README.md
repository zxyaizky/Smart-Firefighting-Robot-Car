# Person V8 参数交付

烧录参数文件：`C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\flash\person_v8\npu_params.bin`

| 项目 | 值 |
|---|---|
| Flash 芯片 | U33 |
| 参数起始字节偏移 | `0x200000` |
| 参数结束（不含） | `0x250000` |
| 文件长度 | 327680 字节 |
| CRC32 | `4c277779` |
| SHA256 | `aa53fb1ad8c48cc56047c4cb0a9fdedbddfbbc1eced38dfa970baebd371e4b27` |
| 检测阈值 | OBJ>=128 且 PERSON>=128 |

在 TD 打开 `C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\td_project\camera_to_dsi_display.al`，重新运行综合、布局布线和位流生成。将新位流用于 FPGA 配置区，V8 参数 bin 用于 U33 的 `0x200000`。新配置数据长度应不超过 `0x200000`，合并时需检查区域没有重叠。现有 40 字节 MCU 拷贝固件可沿用，原地址 `0xE00000`。

本次已同步正式 A 工程的模型描述符、两处参数 CRC、HDMI/以太网框路径及语音通知的阈值。新模型 L6/L7/L8 的 shift 从8变7，L11从3变4；描述符编入位流，必须重新生成位流后使用。原文件和两项阈值测试备份在 `original_A`，逐文件哈希和差异见 `rtl_changes.json`、`rtl_changes.patch`。

`npu_params.bin` 是原始二进制，包含加载器必需的零前缀，使用整个文件，不裁剪。`npu_params.hex` 是逐32位字的文本，不是 Intel HEX；`npu_desc.hex` 是审计文件，没有独立 Flash 地址。优先使用上述 bin 文件。

验证已通过：12层权重/偏置/移位及填充反解析，磁盘 HEX/BIN 一致，INT32 累加器边界检查；空椅子、站立人、坐姿人三组 NumPy 整数参考与 V8 QAT 的全部5400输出字节一致；生产打包 RAM、流式 RGB 输入、DDR 参数加载与 CRC 回读的三组完整12层 RTL 仿真，共 4966200 个阶段值、5400个最终字节一致，差异0；两个128/128阈值边界仿真通过。

本次按要求只交付模型参数及对应源配置，没有运行综合、布局布线、生成新位流、合成完整 Flash 镜像或烧录实板。物理 Flash、DDR PHY 和现场摄像头效果尚未验证。
