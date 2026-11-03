# Person V11 FPGA 参数交付

模型：`C:\Users\lx292\Desktop\safety_grid_v1\runs\qat_person_v11_photo_20261024\best_qat.pth`，SHA256：`e595a361c34689f63634ad1fd7a189657a23c065d4949494e73db23d078988d1`。

参数：`npu_params.bin`，327680字节，CRC32 `0905be5a`，SHA256 `e423fc5327ac94488efae26d029a7a1163cf203eede1685557e1fe7da3239dc1`。

## 合成前的配置替换

正式A工程已同步下列3个文件，无需再次手动替换。若迁移到另一个同版本工程，使用本包 `rtl_update` 按相同相对路径替换。当前工程根目录：

`C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd`

- `user_source/hdl_source/design_top_wrapper.v`
- `td_project/import/npu_u33_mcu_bridge.v`
- `td_project/import/npu_model_config.vh`

正式A工程与替换文件内的两处 `PARAM_CRC32` 均已从 `3198c5f2` 更新为 `0905be5a`。原文件备份在 `original_A`。描述符96个数值与当前V9配置一致，仅版本注释更新为V11；仍提供对应文件避免版本混淆。门限保持OBJ>=128且PERSON>=128。

然后在TD打开 `C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\td_project\camera_to_dsi_display.al`，由你运行综合、布局布线、位流生成。必须使用这次更新CRC后的新位流。

## U33 Flash 合成地址

| 文件 | 起始字节偏移 |
|---|---|
| 你重新生成的FPGA位流 | `0x000000` |
| 本包 `npu_params.bin` | `0x200000` |
| 本包 `u33_boot_fw.bin`（沿用原40字节固件） | `0xE00000` |

新位流配置区预留至 `0x200000`（不含），参数占用 `0x200000` 至 `0x250000`（不含），合并时按此布局避免重叠。参数bin包含必需的零前缀，使用整个文件，不裁剪。字节顺序已按加载器布局导出。

`npu_desc.hex` 仅供审计，描述符编入FPGA位流，没有独立Flash烧录地址；也不需要把 `.pth` 或参数文本HEX加入Flash。

## 已完成的核对

12层全部57368个INT8权重、398个INT32偏置、移位及填充反解析通过；磁盘HEX/BIN一致，INT32累加器边界检查通过。空椅子、站姿、坐姿及新增照片四组，导出bin的整数计算与原QAT模型全部7200个最终输出字节相同，差异0。源QAT权重保持不变；正式A工程已核对与包内V11配置一致，修改前备份与逐文件哈希见 `original_A` 和 `config_updates.json`。

本次未运行RTL仿真、综合、布局布线、生成位流、合成完整Flash镜像或烧录实板。检测表现沿用V11 QAT，包含旧图回放的16张正测试图仍有5张漏检，新增13张负测试图仍有1次误报。
