# Person V5 独立 Flash 参数布局

工程声明 U33 为16MiB；本次未读取实板Flash ID。地址沿用原机制，静态区域检查无重叠。没有合成完整Flash镜像。

| 文件 | 起始偏移 | 结束（不含） | 长度 | CRC32 | SHA256 |
|---|---|---|---:|---|---|
| npu_params.bin | 0x200000 | 0x250000 | 327680 | e27c4b4d | a661813e90036e5072cd93f8ccaaf76cc4cdda4a01d3d4ae94d95572b4cba097 |
| u33_boot_fw.bin | 0xe00000 | 0xe00028 | 40 | ba15afe3 | f347a854f88361652aba9c80c1bead0ed651d98b4b0e23e88087c5b965f1a33c |

后续合成：用户重新生成与本次RTL配套的比特流放0x000000；本目录npu_params.bin放0x200000；本目录u33_boot_fw.bin放0xE00000。固件内容与原来完全一致，可复用。新比特流必须小于等于0x200000字节，否则需重新审核布局。不要复用旧完整Flash镜像或旧参数。

npu_params.hex是小端32位逐字文本（不是Intel HEX）；npu_desc.hex是描述符审计文件，不应单独写入Flash；parameters128.hex仅供仿真。描述符已编入npu_model_config.vh ROM，L2移位及参数CRC变化要求后续重新综合生成比特流，本次没有执行。
