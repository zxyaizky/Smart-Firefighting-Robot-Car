# Person V5 INT8 移植与仿真验证报告

状态：**实验候选版本，尚未通过实板验收。参数编译和完整NPU数值验证通过；存在已确认的旧RTL显示/压力测试失败，不能称全部测试通过。**

本次没有执行综合、布局布线、时序实现、比特流生成、Flash合成、下载或烧录。没有改B工程、训练代码、数据集、现有权重或Python工程中的V3部署文件。

## 实际工程与模型

A工程：`C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\td_project\camera_to_dsi_display.al`，top为design_top_wrapper；.al实际引用当前import目录的网络、参数加载器、bridge和配置头。

选用：`C:\Users\lx292\Desktop\safety_grid_v1\runs\qat_person_v5\best_qat.pth`

SHA256：`3dad459cb82bab3ad6de82c85884f73ffc31e893e101fec50209238d361a4579`。Compared SC500 localization and false alarms at all requested gates, then original validation; best wins ties. Full byte differences are reported separately.

参考的compare_person_fp32_qat_v5.py实际不存在；已在本目录scripts/evaluate_v5.py建立只读评估适配。实际存在的compare_fp32_person_v3_v5.py仅为FP32对比；本次按相同数据读取、字节化、max-OBJ及IoU约定重新计算。169张VALID全部评估；TEST未读取。旧300帧另作无标注门限通过率复核，不能当IoU准确率或独立实拍验收集。

### V5 QAT initial

| 数据组/门限 | 人体检出 | 人体IoU50 | 无人误报 | 无人拒绝率 |
|---|---:|---:|---:|---:|
| SC500 128/128 | 16/20 | 16/20 (80.00%) | 0/19 | 100.00% |
| SC500 96/64 | 20/20 | 16/20 (80.00%) | 0/19 | 100.00% |
| SC500 64/32 | 20/20 | 16/20 (80.00%) | 0/19 | 100.00% |
| original 128/128 | 109/110 | 65/110 (59.09%) | 4/20 | 80.00% |
| original 96/64 | 109/110 | 65/110 (59.09%) | 6/20 | 70.00% |
| original 64/32 | 109/110 | 65/110 (59.09%) | 9/20 | 55.00% |
| all 128/128 | 125/130 | 81/130 (62.31%) | 4/39 | 89.74% |
| all 96/64 | 129/130 | 81/130 (62.31%) | 6/39 | 84.62% |
| all 64/32 | 129/130 | 81/130 (62.31%) | 9/39 | 76.92% |

### V5 QAT best

| 数据组/门限 | 人体检出 | 人体IoU50 | 无人误报 | 无人拒绝率 |
|---|---:|---:|---:|---:|
| SC500 128/128 | 16/20 | 16/20 (80.00%) | 0/19 | 100.00% |
| SC500 96/64 | 20/20 | 16/20 (80.00%) | 0/19 | 100.00% |
| SC500 64/32 | 20/20 | 16/20 (80.00%) | 0/19 | 100.00% |
| original 128/128 | 109/110 | 65/110 (59.09%) | 4/20 | 80.00% |
| original 96/64 | 109/110 | 65/110 (59.09%) | 6/20 | 70.00% |
| original 64/32 | 109/110 | 65/110 (59.09%) | 9/20 | 55.00% |
| all 128/128 | 125/130 | 81/130 (62.31%) | 4/39 | 89.74% |
| all 96/64 | 129/130 | 81/130 (62.31%) | 6/39 | 84.62% |
| all 64/32 | 129/130 | 81/130 (62.31%) | 9/39 | 76.92% |

初始/最佳逐字节差异：验证集 16951/304200 字节不同，涉及169张；旧300帧 29848/540000 字节不同，涉及300张；最大绝对差8。汇总指标相同不等于输出相同。本次按SC500定位/误报、原验证组表现比较，指标并列时选择best，未仅凭loss选择。

## 编译契约与RTL改动

12层拓扑保持，57368个INT8权重、398个INT32偏置、12个移位；16-lane补零与参数前缀使总参数81920个32位字=327680字节。权重布局为[OC组][IC组][IC lane][OC lane][KY][KX]，小端序；所有导出权重、偏置、移位和补齐lane均反向解码核对。INT32累加界限对所有uint8输入作保守证明。BN Folding、round-to-nearest-even量化、ReLU/HardSigmoid及算术右移均沿用QAT整数规则。

移位：`[6, 7, 8, 8, 7, 7, 8, 8, 8, 8, 7, 3]`；相较V3只有L2从7变8。参数CRC：`e27c4b4d`。

实际修改仅三份RTL配置（备份original_A，差异rtl_changes.patch）：

- `C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\td_project\import\npu_model_config.vh`
- `C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\user_source\hdl_source\design_top_wrapper.v`
- `C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\td_project\import\npu_u33_mcu_bridge.v`

npu_model_config.vh更新V5描述符；顶层和npu_u33_mcu_bridge的参数CRC同步。参数大小、Flash偏移、NPU计算核心、卷积拓扑、RGB视频、160x90采样、补黑、HDMI叠加逻辑均未修改。当前三处门限保持OBJ>=64/PERSON>=32，未因模型训练128/128约定而擅自调门限。

## Python / 编译参数 / 完整RTL数值一致性

| 输入 | QAT vs 参数整数参考 | RTL逐层比较值数 | 最终字节数 | 差异/最大误差 | 最大OBJ并列格数 |
|---|---|---:|---:|---|---:|
| original_person | PASS | 1655400 | 1800 | 0 / 0 | 1 |
| original_background | PASS | 1655400 | 1800 | 0 / 0 | 1 |
| sc500_person | PASS | 1655400 | 1800 | 0 / 0 | 1 |
| sc500_background | PASS | 1655400 | 1800 | 0 / 0 | 1 |
| zero | PASS | 1655400 | 1800 | 0 / 0 | 12 |
| white_active | PASS | 1655400 | 1800 | 0 / 0 | 10 |
| rgb_ramp | PASS | 1655400 | 1800 | 0 / 0 | 1 |

共 11587800 个C/B/A/Q/O阶段值、12600个最终输出字节逐项一致。每组均执行完整12层，检查实际权重DMA顺序、每层尺寸、写地址唯一性、补齐输出、最终最大OBJ winner字节；zero和white_active分别含12和10个并列最大格，RTL保持首个行优先最大值。生产RGB输入打包分支将RGB流写入CHW PING，并验证上下黑边。

每个网络用例先经生产npu_param_loader、DDR调度/读桥把完整327680字节上传并CRC回读，之后执行NPU。外部存储为行为native DDR模型，不包含物理DDR PHY、模拟IO、布线时序或实板测试。源快照与simulated_rtl_hashes.json记录实际模拟RTL。observed.txt及reference.npz保留全阶段证据。

## 框、加载与边界验证（包含失败）

- 原生160x120框：183/183 PASS；检测门限、source frame ID和result ID均PASS。
- HDMI坐标：180/183 PASS，另3例FAIL。旧逻辑在DX>10*W时把本应为正的左边界span取绝对值后仍相减。本次未改该模块；与上次64/32源文件按统一换行符比较完全相同。
  - `original_303df2a476f606e13944e6c6c74469f4a02456876fb33d1fe6dcce730115b9ae.jpg`：HDMI x1期望648、实际632，其它三条边一致；原生坐标正确。
  - `original_3472502e93f8993abc3182dcbc90c751b22966a443b89f38156e473a6fa6f51a.jpg`：HDMI x1期望706、实际702，其它三条边一致；原生坐标正确。
  - `original_eed0a76c75ff048a8c0cb9901241e6a627710435bb374cf0e4c1c9df92355ab1.jpg`：HDMI x1期望652、实际628，其它三条边一致；原生坐标正确。

该问题不改变PERSON/OBJ或检测有效标志，但会使部分细窄目标的HDMI框左边界偏左。本任务按要求保留显示链路，未擅自改正；bbox_verification.json完整列出全部183例与失败值。

- `tb_u33_bridge`：**PASS**
- `tb_u33_ddr_boot`：**PASS**
- `tb_npu_result_overlay`：**PASS**
- `tb_npu_bbox_threshold`：**PASS**
- `integer_boundaries`：**PASS**
- `rgb_continuous`：**PASS**
- `rgb_reset`：**PASS**
- `rgb_slow_npu`：**FAIL**。历史已存在问题，本次复现：视频约71.43MHz、NPU20MHz时，PING清零期间256-token FIFO溢出，仅收765/43200字节，推理停住；需要复位，未修复。正常配置NPU100MHz的continuous/reset测试通过。
- `rgb_edges`：**PASS**

U33测试覆盖完整81920个AHB字/20480个128bit块、背压/复位以及并发视频DDR读写。固件静态解码及完整AHB/DDR路径均兼容V5相同参数长度；未模拟硬MCU CPU内部执行。整数边界测试覆盖INT32极值、HardSigmoid、0..15全部移位及量化截断边界。

## Flash文件与后续操作

工程声明 U33 为16MiB；本次未读取实板Flash ID。地址沿用原机制，静态区域检查无重叠。没有合成完整Flash镜像。

| 文件 | 起始偏移 | 结束（不含） | 长度 | CRC32 | SHA256 |
|---|---|---|---:|---|---|
| npu_params.bin | 0x200000 | 0x250000 | 327680 | e27c4b4d | a661813e90036e5072cd93f8ccaaf76cc4cdda4a01d3d4ae94d95572b4cba097 |
| u33_boot_fw.bin | 0xe00000 | 0xe00028 | 40 | ba15afe3 | f347a854f88361652aba9c80c1bead0ed651d98b4b0e23e88087c5b965f1a33c |

后续合成：用户重新生成与本次RTL配套的比特流放0x000000；本目录npu_params.bin放0x200000；本目录u33_boot_fw.bin放0xE00000。固件内容与原来完全一致，可复用。新比特流必须小于等于0x200000字节，否则需重新审核布局。不要复用旧完整Flash镜像或旧参数。

npu_params.hex是小端32位逐字文本（不是Intel HEX）；npu_desc.hex是描述符审计文件，不应单独写入Flash；parameters128.hex仅供仿真。描述符已编入npu_model_config.vh ROM，L2移位及参数CRC变化要求后续重新综合生成比特流，本次没有执行。

**本目录两个bin是独立payload，不是完整Flash镜像。**npu_params.bin必须与新V5描述符/CRC的比特流配套，不能直接配旧best_result比特流。旧deployment/npu12中历史manifest/完整镜像未覆盖，其中有旧火焰/V3配置，后续以本目录flash_layout.json为准。

## 未解决事项与实际完成状态

1. 编译和7组完整NPU数值一致性已完成；不是所有RTL回归通过，HDMI细框左边界3例以及slow_npu压力测试明确FAIL。
2. 候选尚未实板验收、未作时序验证；SC500 VALID仅20张有人/19张无人，且来源为历史摄像头数据，不能代表新场景。低门限64/32在原验证组误报9/20，不能把SC500的0/19误报推广为全场景无误报。
3. 训练修复数据已是160x90内容图，loader只补一次15行；本次未改FPGA预处理，也没有修改原始数据。
4. TEST未读取；新比特流尺寸和实际Flash型号仍需用户后续构建/实板时确认。
5. Python工程和修复数据集的完整文件大小/mtime清单前后相同，关键训练代码/权重/V3部署文件SHA256相同，见readonly_verification.json。

复现顺序：scripts/evaluate_v5.py → scripts/prepare_v5.py → scripts/run_network_v5.py、scripts/run_regressions_v5.py、scripts/check_bbox_v5.py → scripts/finalize_v5.py。使用现有yolo环境，建议python -B禁止写训练工程的pycache。prepare脚本保留初始备份，已处于本次V5状态时可安全重跑。所有工具命令仅Python/ModelSim仿真，commands.jsonl记录仿真调用。
