# Person V9 参数交付

烧录参数文件：`C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\flash\person_v9\npu_params.bin`

| 项目 | 值 |
|---|---|
| Flash 芯片 | U33 |
| 参数起始字节偏移 | `0x200000` |
| 参数结束（不含） | `0x250000` |
| 文件长度 | 327680 字节 |
| CRC32 | `3198c5f2` |
| SHA256 | `4a2a017902636861e7dc6cad045e94579c373eda77453bae91df6590453a1100` |
| 检测阈值 | OBJ>=128 且 PERSON>=128 |

在 TD 打开 `C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\td_project\camera_to_dsi_display.al`，重新运行综合、布局布线和位流生成。将新位流用于 FPGA 配置区，V9 参数 bin 用于 U33 的 `0x200000`。新配置数据长度应不超过 `0x200000`，合并时需检查区域没有重叠。现有 40 字节 MCU 拷贝固件可沿用，原地址 `0xE00000`。

本次已同步正式 A 工程的两处参数 CRC 和模型描述符版本标记，量化移位及 OBJ/PERSON 的128/128门限与V8一致。原文件备份在 `original_A`，逐文件哈希和差异见 `rtl_changes.json`、`rtl_changes.patch`。请重新生成位流，以便启动加载器使用V9参数CRC。

`npu_params.bin` 是原始二进制，包含加载器必需的零前缀，使用整个文件，不裁剪。`npu_params.hex` 是逐32位字的文本，不是 Intel HEX；`npu_desc.hex` 是审计文件，没有独立 Flash 地址。优先使用上述 bin 文件。

验证已通过：12层权重/偏置/移位及填充反解析，磁盘 HEX/BIN 一致，INT32 累加器边界检查；空椅子、站立人、坐姿人、新增照片四组 NumPy 整数参考与用户确认的 V9 QAT 的全部7200输出字节一致；生产打包 RAM、流式 RGB 输入、DDR 参数加载与 CRC 回读的四组完整12层 RTL 仿真，共 6621600 个阶段值、7200个最终字节一致，差异0；两个128/128阈值边界仿真通过。

本次按要求只交付模型参数及对应源配置，没有运行综合、布局布线、生成新位流、合成完整 Flash 镜像或烧录实板。物理 Flash、DDR PHY 和 FPGA 实板摄像头效果尚未验证。本次验证的是导出与推理计算一致性；Python检测质量以已确认的V9模型为准。
