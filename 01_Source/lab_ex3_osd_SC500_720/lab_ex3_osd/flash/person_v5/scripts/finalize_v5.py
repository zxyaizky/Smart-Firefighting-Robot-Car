"""Finalize independent Flash payload layout and truthful simulation/limitation reports."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import hashlib,json,zlib,re
import compiler_person_v5 as comp
OUT=comp.DEFAULT_RTL/'flash/person_v5';RTL=comp.DEFAULT_RTL

def main():
    cfg=json.loads((OUT/'deployment.json').read_text())
    selection=json.loads((OUT/'selection.json').read_text())
    evaluation=json.loads((OUT/'evaluation.json').read_text())
    python=json.loads((OUT/'python_verification.json').read_text())
    network=json.loads((OUT/'rtl_network_verification.json').read_text());assert network['result']=='PASS'
    regression=json.loads((OUT/'regression_verification.json').read_text())
    bbox=json.loads((OUT/'bbox_verification.json').read_text())
    baseline=json.loads((OUT/'readonly_before.json').read_text())
    integrity=[]
    for text,digest in baseline['critical_sha256'].items():
        path=Path(text);assert comp.sha(path)==digest,('protected SHA changed',text)
    for root_text,before in baseline['metadata'].items():
        root=Path(root_text)
        after={str(p.relative_to(root)):[p.stat().st_size,p.stat().st_mtime_ns] for p in root.rglob('*') if p.is_file()}
        changed=[k for k in before if before[k]!=after.get(k)]
        added=sorted(set(after)-set(before));assert not changed and not added,(root_text,changed[:4],added[:4])
        integrity.append(dict(root=root_text,protected_files=len(before),metadata_unchanged=True))
    comp.write_json(OUT/'readonly_verification.json',dict(result='PASS',roots=integrity,critical_sha256_unchanged=baseline['critical_sha256']))
    # Parse the actual gates in all three production modules, do not tune them.
    gates={}
    for rel,patterns in {
        'td_project/import/npu_result_overlay.v':[r'result_npu_reg\[7:0\] >= 8\x27d(\d+)',r'result_npu_reg\[47:40\] >= 8\x27d(\d+)'],
        'td_project/import/npu_bbox_overlay_160x120.v':[r'offset_obj_reg >= 8\x27d(\d+)',r'offset_fire_reg >= 8\x27d(\d+)'],
        'user_source/hdl_source/design_top_wrapper.v':[r'S_npu_tensor_data\[7:0\] >= 8\x27d(\d+)',r'S_npu_tensor_data\[47:40\] >= 8\x27d(\d+)']}.items():
        text=(RTL/rel).read_text(encoding='utf-8');gates[rel]=[int(re.search(p,text).group(1)) for p in patterns]
        assert gates[rel]==[64,32],(rel,gates[rel])
    for rel in ['user_source/hdl_source/design_top_wrapper.v','td_project/import/npu_u33_mcu_bridge.v']:
        assert (RTL/rel).read_text(encoding='utf-8').count("32'h"+cfg['crc32'])==1
    assert comp.sha(RTL/'td_project/import/npu_model_config.vh')==comp.sha(OUT/'npu_model_config.vh')
    binary=[]
    for name,start,role in [('npu_params.bin',0x200000,'Person V5 INT8 weights, INT32 biases, shifts and loader padding'),('u33_boot_fw.bin',0xe00000,'Existing compatible U33 MCU copy firmware, copied byte-identical')]:
        path=OUT/name;raw=path.read_bytes();end=start+len(raw)
        binary.append(dict(file=name,absolute_path=str(path),size_bytes=len(raw),flash_start=f'0x{start:06x}',flash_end_exclusive=f'0x{end:06x}',flash_end_inclusive=f'0x{end-1:06x}',
            crc32=f'{zlib.crc32(raw):08x}',sha256=comp.sha(path),model='Person V5 geometry_fixed',quantization=cfg['qat_recipe'],purpose=role))
    current_bitstream=RTL/'td_project/camera_to_dsi_display_Runs/best_result/camera_to_dsi_display.bin'
    assert current_bitstream.exists() and current_bitstream.stat().st_size<=0x200000
    regions=[(0,current_bitstream.stat().st_size,'current old bitstream, not a V5 artifact'),(0x200000,0x250000,'V5 params'),(0xe00000,0xe00028,'MCU firmware')]
    assert all(0<=a<b<=0x1000000 for a,b,n in regions)
    assert all(b<=c for (a,b,n),(c,d,m) in zip(regions,regions[1:])),regions
    layout=dict(device='U33 GD25WQ128ESIGR',declared_flash_capacity_bytes=0x1000000,
        capacity_source='existing deployment/npu12/u33_flash_manifest.json and sim/build_u33_image.py; physical JEDEC ID not read',
        binaries=binary,offsets_reused=True,regions_nonoverlapping=True,new_combined_flash_image_generated=False,
        fpga_configuration=dict(start='0x000000',reserved_end_exclusive='0x200000',existing_bitstream_size_bytes=current_bitstream.stat().st_size,
            existing_bitstream_sha256=comp.sha(current_bitstream),existing_bitstream_is_v5=False,new_bitstream_required=True,
            user_must_check_new_bitstream_size_at_merge=True),
        descriptors=dict(file=str(OUT/'npu_desc.hex'),storage='compiled npu_model_config.vh ROM, not a separate Flash region',flash_offset=None),
        mcu_xip_parameter_source='0x20200000..0x20250000',mcu_reset_vector='0x20e00000',ahb_destination='0x80000000',
        npu_ddr_halfword_base='0xc00000',native_ddr_halfword_base='0x1800000',native_ddr_byte_base='0x3000000')
    comp.write_json(OUT/'flash_layout.json',layout)
    flashmd='# Person V5 独立 Flash 参数布局\n\n工程声明 U33 为16MiB；本次未读取实板Flash ID。地址沿用原机制，静态区域检查无重叠。没有合成完整Flash镜像。\n\n'
    flashmd+='| 文件 | 起始偏移 | 结束（不含） | 长度 | CRC32 | SHA256 |\n|---|---|---|---:|---|---|\n'
    for f in binary:flashmd+=f"| {f['file']} | {f['flash_start']} | {f['flash_end_exclusive']} | {f['size_bytes']} | {f['crc32']} | {f['sha256']} |\n"
    flashmd+='\n后续合成：用户重新生成与本次RTL配套的比特流放0x000000；本目录npu_params.bin放0x200000；本目录u33_boot_fw.bin放0xE00000。固件内容与原来完全一致，可复用。新比特流必须小于等于0x200000字节，否则需重新审核布局。不要复用旧完整Flash镜像或旧参数。\n\nnpu_params.hex是小端32位逐字文本（不是Intel HEX）；npu_desc.hex是描述符审计文件，不应单独写入Flash；parameters128.hex仅供仿真。描述符已编入npu_model_config.vh ROM，L2移位及参数CRC变化要求后续重新综合生成比特流，本次没有执行。\n'
    (OUT/'flash_layout.md').write_text(flashmd,encoding='utf-8')
    active_changes=json.loads((OUT/'rtl_changes.json').read_text())
    # Self-contained report first; manifest then records payload/report/script hashes.
    md='''# Person V5 INT8 移植与仿真验证报告

状态：**实验候选版本，尚未通过实板验收。参数编译和完整NPU数值验证通过；存在已确认的旧RTL显示/压力测试失败，不能称全部测试通过。**

本次没有执行综合、布局布线、时序实现、比特流生成、Flash合成、下载或烧录。没有改B工程、训练代码、数据集、现有权重或Python工程中的V3部署文件。

## 实际工程与模型

'''
    md+=f"A工程：`{RTL/'td_project/camera_to_dsi_display.al'}`，top为design_top_wrapper；.al实际引用当前import目录的网络、参数加载器、bridge和配置头。\n\n"
    md+=f"选用：`{selection['checkpoint']}`\n\nSHA256：`{selection['sha256']}`。{selection['reason']}\n\n"
    md+='参考的compare_person_fp32_qat_v5.py实际不存在；已在本目录scripts/evaluate_v5.py建立只读评估适配。实际存在的compare_fp32_person_v3_v5.py仅为FP32对比；本次按相同数据读取、字节化、max-OBJ及IoU约定重新计算。169张VALID全部评估；TEST未读取。旧300帧另作无标注门限通过率复核，不能当IoU准确率或独立实拍验收集。\n\n'
    for name in ['initial','best']:
        md+=f"### V5 QAT {name}\n\n| 数据组/门限 | 人体检出 | 人体IoU50 | 无人误报 | 无人拒绝率 |\n|---|---:|---:|---:|---:|\n"
        for group in ['SC500','original','all']:
            for gate in ['128/128','96/64','64/32']:
                x=evaluation['metrics'][name][group][gate]
                md+=f"| {group} {gate} | {x['detected_positive']}/{x['positives']} | {x['positive_iou50_count']}/{x['positives']} ({x['positive_iou50_percent']:.2f}%) | {x['false_positives']}/{x['negatives']} | {x['negative_rejection_percent']:.2f}% |\n"
        md+='\n'
    diff=evaluation['initial_best_output_differences']
    md+=f"初始/最佳逐字节差异：验证集 {diff['validation_changed']}/{diff['validation_bytes']} 字节不同，涉及{diff['validation_frames_changed']}张；旧300帧 {diff['raw_capture_changed']}/{diff['raw_capture_bytes']} 字节不同，涉及{diff['raw_capture_frames_changed']}张；最大绝对差{diff['max_abs']}。汇总指标相同不等于输出相同。本次按SC500定位/误报、原验证组表现比较，指标并列时选择best，未仅凭loss选择。\n\n"
    md+='## 编译契约与RTL改动\n\n'
    md+=f"12层拓扑保持，57368个INT8权重、398个INT32偏置、12个移位；16-lane补零与参数前缀使总参数81920个32位字=327680字节。权重布局为[OC组][IC组][IC lane][OC lane][KY][KX]，小端序；所有导出权重、偏置、移位和补齐lane均反向解码核对。INT32累加界限对所有uint8输入作保守证明。BN Folding、round-to-nearest-even量化、ReLU/HardSigmoid及算术右移均沿用QAT整数规则。\n\n移位：`{[x['shift'] for x in cfg['layers']]}`；相较V3只有L2从7变8。参数CRC：`{cfg['crc32']}`。\n\n"
    md+='实际修改仅三份RTL配置（备份original_A，差异rtl_changes.patch）：\n\n'
    for x in active_changes:md+=f"- `{x['path']}`\n"
    md+='\nnpu_model_config.vh更新V5描述符；顶层和npu_u33_mcu_bridge的参数CRC同步。参数大小、Flash偏移、NPU计算核心、卷积拓扑、RGB视频、160x90采样、补黑、HDMI叠加逻辑均未修改。当前三处门限保持OBJ>=64/PERSON>=32，未因模型训练128/128约定而擅自调门限。\n\n'
    md+='## Python / 编译参数 / 完整RTL数值一致性\n\n| 输入 | QAT vs 参数整数参考 | RTL逐层比较值数 | 最终字节数 | 差异/最大误差 | 最大OBJ并列格数 |\n|---|---|---:|---:|---|---:|\n'
    for p,n in zip(python['cases'],network['cases']):
        assert p['name']==n['case']
        md+=f"| {p['name']} | PASS | {n['stage_value_comparisons']} | 1800 | 0 / 0 | {p['max_obj_tied_cells']} |\n"
    md+=f"\n共 {network['stage_value_comparisons']} 个C/B/A/Q/O阶段值、{network['final_byte_comparisons']}个最终输出字节逐项一致。每组均执行完整12层，检查实际权重DMA顺序、每层尺寸、写地址唯一性、补齐输出、最终最大OBJ winner字节；zero和white_active分别含12和10个并列最大格，RTL保持首个行优先最大值。生产RGB输入打包分支将RGB流写入CHW PING，并验证上下黑边。\n\n"
    md+='每个网络用例先经生产npu_param_loader、DDR调度/读桥把完整327680字节上传并CRC回读，之后执行NPU。外部存储为行为native DDR模型，不包含物理DDR PHY、模拟IO、布线时序或实板测试。源快照与simulated_rtl_hashes.json记录实际模拟RTL。observed.txt及reference.npz保留全阶段证据。\n\n'
    md+='## 框、加载与边界验证（包含失败）\n\n'
    md+=f"- 原生160x120框：{bbox['native_passed']}/{bbox['cases']} PASS；检测门限、source frame ID和result ID均PASS。\n"
    md+=f"- HDMI坐标：{bbox['hdmi_passed']}/{bbox['cases']} PASS，另{len(bbox['failures'])}例FAIL。旧逻辑在DX>10*W时把本应为正的左边界span取绝对值后仍相减。本次未改该模块；与上次64/32源文件按统一换行符比较完全相同。\n"
    for x in bbox['failures']:md+=f"  - `{Path(x['name']).name}`：HDMI x1期望{x['expected']['hdmi'][0]}、实际{x['actual_hdmi'][0]}，其它三条边一致；原生坐标正确。\n"
    md+='\n该问题不改变PERSON/OBJ或检测有效标志，但会使部分细窄目标的HDMI框左边界偏左。本任务按要求保留显示链路，未擅自改正；bbox_verification.json完整列出全部183例与失败值。\n\n'
    for x in regression['checks']:
        md+=f"- `{x['test']}`：**{x['result']}**"
        if x['test']=='rgb_slow_npu':md+=f"。历史已存在问题，本次复现：视频约71.43MHz、NPU20MHz时，PING清零期间256-token FIFO溢出，仅收{x['actual_rgb_bytes']}/43200字节，推理停住；需要复位，未修复。正常配置NPU100MHz的continuous/reset测试通过。"
        md+='\n'
    md+='\nU33测试覆盖完整81920个AHB字/20480个128bit块、背压/复位以及并发视频DDR读写。固件静态解码及完整AHB/DDR路径均兼容V5相同参数长度；未模拟硬MCU CPU内部执行。整数边界测试覆盖INT32极值、HardSigmoid、0..15全部移位及量化截断边界。\n\n'
    md+='## Flash文件与后续操作\n\n'
    md+=flashmd.split('\n\n',1)[1]
    md+='\n**本目录两个bin是独立payload，不是完整Flash镜像。**npu_params.bin必须与新V5描述符/CRC的比特流配套，不能直接配旧best_result比特流。旧deployment/npu12中历史manifest/完整镜像未覆盖，其中有旧火焰/V3配置，后续以本目录flash_layout.json为准。\n\n'
    md+='## 未解决事项与实际完成状态\n\n1. 编译和7组完整NPU数值一致性已完成；不是所有RTL回归通过，HDMI细框左边界3例以及slow_npu压力测试明确FAIL。\n2. 候选尚未实板验收、未作时序验证；SC500 VALID仅20张有人/19张无人，且来源为历史摄像头数据，不能代表新场景。低门限64/32在原验证组误报9/20，不能把SC500的0/19误报推广为全场景无误报。\n3. 训练修复数据已是160x90内容图，loader只补一次15行；本次未改FPGA预处理，也没有修改原始数据。\n4. TEST未读取；新比特流尺寸和实际Flash型号仍需用户后续构建/实板时确认。\n5. Python工程和修复数据集的完整文件大小/mtime清单前后相同，关键训练代码/权重/V3部署文件SHA256相同，见readonly_verification.json。\n\n复现顺序：scripts/evaluate_v5.py → scripts/prepare_v5.py → scripts/run_network_v5.py、scripts/run_regressions_v5.py、scripts/check_bbox_v5.py → scripts/finalize_v5.py。使用现有yolo环境，建议python -B禁止写训练工程的pycache。prepare脚本保留初始备份，已处于本次V5状态时可安全重跑。所有工具命令仅Python/ModelSim仿真，commands.jsonl记录仿真调用。\n'
    (OUT/'verification_report.md').write_text(md,encoding='utf-8')
    files=[]
    skip_dirs={'work','__pycache__'}
    for p in sorted(OUT.rglob('*')):
        if not p.is_file() or any(x in p.parts for x in skip_dirs) or p.name in ['manifest.json'] or p.suffix in ['.wlf','.vstf']:continue
        if 'simulation' in p.parts or 'regression' in p.parts:
            # Separate simulated_rtl_hashes and detailed check reports track source copies.
            if p.suffix in ['.v','.vh','.py','.hex'] or p.name in ['modelsim.ini','transcript']:continue
        files.append(dict(path=str(p),relative_path=str(p.relative_to(OUT)),size_bytes=p.stat().st_size,sha256=comp.sha(p)))
    manifest=dict(format='person-v5-fpga-candidate-v1',status='EXPERIMENTAL_CANDIDATE_WITH_KNOWN_RTL_FAILURES',selected_checkpoint=selection,
        model_topology=cfg['model_id'],quantization=cfg['qat_recipe'],active_gates=gates,flash_binaries=binary,modified_active_files=active_changes,
        new_files_root=str(OUT),files=files,validation=dict(compiler='PASS',python='PASS',network='PASS',bbox=bbox['result'],regression=regression['result'],physical_board='NOT_TESTED'),
        forbidden_operations_executed=[],requires_new_bitstream=True)
    comp.write_json(OUT/'manifest.json',manifest)
    print(json.dumps(dict(final_status=manifest['status'],flash_binaries=binary,network_comparisons=network['stage_value_comparisons'],readonly='PASS',files=len(files)),indent=2),flush=True)

if __name__=='__main__':main()
