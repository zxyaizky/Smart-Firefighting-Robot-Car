"""Write verified V9 parameter placement/provenance; never build a full Flash image."""
from pathlib import Path
import hashlib
import json
import re
import zlib

OUT = Path(__file__).resolve().parents[1]
RTL = OUT.parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    cfg = json.loads((OUT/'deployment.json').read_text())
    checks = json.loads((OUT/'compiler_checks.json').read_text())
    python = json.loads((OUT/'python_verification.json').read_text())
    network = json.loads((OUT/'rtl_network_verification.json').read_text())
    gates = json.loads((OUT/'gate_verification.json').read_text())
    assert all(report['result']=='PASS' for report in (checks,python,network,gates))
    assert len(network['cases'])==4 and network['mismatches']==0
    raw = (OUT/'npu_params.bin').read_bytes()
    assert len(raw)==327680 and f'{zlib.crc32(raw):08x}'==cfg['crc32']=='3198c5f2'
    assert sha(Path(cfg['checkpoint']))==cfg['checkpoint_sha256']
    assert (RTL/'td_project/import/npu_model_config.vh').read_bytes()==(OUT/'npu_model_config.vh').read_bytes()
    assert cfg['output']['obj_threshold']==cfg['output']['person_threshold']==128
    for rel in ('user_source/hdl_source/design_top_wrapper.v','td_project/import/npu_u33_mcu_bridge.v'):
        source=(RTL/rel).read_text(encoding='utf-8')
        assert re.search(r"PARAM_CRC32\s*(?:\(\s*|=\s*)32'h3198c5f2",source),rel
    for record in json.loads((OUT/'rtl_changes.json').read_text()):
        assert sha(Path(record['path']))==record['after_sha256']
        assert sha(Path(record['backup']))==record['before_sha256']
    for copied in (OUT/'simulation/td_project/import').iterdir():
        if copied.suffix in ('.v','.vh'):
            assert sha(copied)==sha(RTL/'td_project/import'/copied.name),copied.name
    fw=RTL/'deployment/npu12/u33_boot_fw.bin'
    assert fw.stat().st_size==40 and sha(fw)=='f347a854f88361652aba9c80c1bead0ed651d98b4b0e23e88087c5b965f1a33c'
    layout=dict(model='Person V9 new-photo fine-tune',
        parameter_file=str(OUT/'npu_params.bin'),size_bytes=len(raw),sha256=sha(OUT/'npu_params.bin'),
        crc32=cfg['crc32'],flash_device='U33',flash_start='0x200000',flash_end_exclusive='0x250000',
        word_byte_order='little endian; raw binary file order',
        rtl_project=str(RTL/'td_project/camera_to_dsi_display.al'),
        new_fpga_bitstream_required=True,fpga_config_offset='0x000000',
        fpga_config_reserved_end_exclusive='0x200000',
        mcu_firmware=dict(existing_compatible_file=str(fw),offset='0xe00000',sha256=sha(fw),unchanged=True),
        descriptor_storage='npu_model_config.vh compiled into FPGA; no separate Flash address',
        combined_flash_image_generated=False,synthesis_run=False,place_route_run=False,
        physical_board_verified=False)
    (OUT/'flash_layout.json').write_text(json.dumps(layout,indent=2),encoding='utf-8')
    text=f'''# Person V9 参数交付

烧录参数文件：`{OUT / 'npu_params.bin'}`

| 项目 | 值 |
|---|---|
| Flash 芯片 | U33 |
| 参数起始字节偏移 | `0x200000` |
| 参数结束（不含） | `0x250000` |
| 文件长度 | 327680 字节 |
| CRC32 | `3198c5f2` |
| SHA256 | `{layout['sha256']}` |
| 检测阈值 | OBJ>=128 且 PERSON>=128 |

在 TD 打开 `{layout['rtl_project']}`，重新运行综合、布局布线和位流生成。将新位流用于 FPGA 配置区，V9 参数 bin 用于 U33 的 `0x200000`。新配置数据长度应不超过 `0x200000`，合并时需检查区域没有重叠。现有 40 字节 MCU 拷贝固件可沿用，原地址 `0xE00000`。

本次已同步正式 A 工程的两处参数 CRC 和模型描述符版本标记，量化移位及 OBJ/PERSON 的128/128门限与V8一致。原文件备份在 `original_A`，逐文件哈希和差异见 `rtl_changes.json`、`rtl_changes.patch`。请重新生成位流，以便启动加载器使用V9参数CRC。

`npu_params.bin` 是原始二进制，包含加载器必需的零前缀，使用整个文件，不裁剪。`npu_params.hex` 是逐32位字的文本，不是 Intel HEX；`npu_desc.hex` 是审计文件，没有独立 Flash 地址。优先使用上述 bin 文件。

验证已通过：12层权重/偏置/移位及填充反解析，磁盘 HEX/BIN 一致，INT32 累加器边界检查；空椅子、站立人、坐姿人、新增照片四组 NumPy 整数参考与用户确认的 V9 QAT 的全部7200输出字节一致；生产打包 RAM、流式 RGB 输入、DDR 参数加载与 CRC 回读的四组完整12层 RTL 仿真，共 {network['stage_value_comparisons']} 个阶段值、7200个最终字节一致，差异0；两个128/128阈值边界仿真通过。

本次按要求只交付模型参数及对应源配置，没有运行综合、布局布线、生成新位流、合成完整 Flash 镜像或烧录实板。物理 Flash、DDR PHY 和 FPGA 实板摄像头效果尚未验证。本次验证的是导出与推理计算一致性；Python检测质量以已确认的V9模型为准。
'''
    (OUT/'README.md').write_text(text,encoding='utf-8')
    manifest=dict(result='PASS',layout=layout,verification=dict(stage_value_comparisons=network['stage_value_comparisons'],
        final_byte_comparisons=7200,mismatches=0,production_packed_ram=True),files=[])
    for path in sorted(OUT.rglob('*')):
        if path.is_file() and 'simulation' not in path.relative_to(OUT).parts and path.name!='manifest.json':
            manifest['files'].append(dict(path=str(path),size_bytes=path.stat().st_size,sha256=sha(path)))
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps(dict(result='PASS',parameters=str(OUT/'npu_params.bin'),size=len(raw),crc32=cfg['crc32'],
                         sha256=layout['sha256'],rtl_stage_comparisons=network['stage_value_comparisons'])),flush=True)


if __name__=='__main__': main()
