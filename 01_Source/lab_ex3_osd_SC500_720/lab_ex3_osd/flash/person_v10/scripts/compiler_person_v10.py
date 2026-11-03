"""Person V10 compiler for the audited A-board 16-lane NPU; no Flash packaging.

Run with the existing yolo environment. Training checkpoints are read-only.
The QAT module is the authority for BN folding, scales and integer rounding.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import zlib
import numpy as np
import torch


ROOT = Path(r'C:\Users\lx292\Desktop\safety_grid_v1')
import sys
sys.dont_write_bytecode = True
sys.path.insert(0,str(ROOT))
from contract_person import LAYER_SPECS, TOPOLOGY_ID, LOADER_PARAMETER_WORDS, ACTIVE_PARAMETER_WORDS
from model_person import SafetyGridNetL
import qat_person_v4 as qat
DEFAULT_RTL = Path(r'C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, obj):
    Path(path).write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def hexfile(path, values, digits):
    Path(path).write_text(''.join(f'{int(v):0{digits}x}\n' for v in values), encoding='ascii')


def load_quantized(checkpoint):
    p = torch.load(checkpoint, map_location='cpu', weights_only=False)
    assert p['format'] == 'safety-grid-person-v1-qat-checkpoint-v1'
    assert p['topology_id'] == TOPOLOGY_ID and p['phase'] == 'qat'
    assert p['qat_recipe'] == qat.QAT_RECIPE_ID and p['representation'] == 'rgb'
    assert p['gate_bytes']['decision'] == 128
    assert set(p['activation_ranges']) == {s.name for s in LAYER_SPECS}
    assert p['activation_ranges']['L11'] == 1.0
    for i in range(11):
        assert math.isfinite(p['activation_ranges'][f'L{i}']) and p['activation_ranges'][f'L{i}'] > 0
        assert p['activation_scales'][f'L{i}'] == p['training_activation_scales'][f'L{i}'] > 0
    model = SafetyGridNetL().eval()
    model.load_state_dict(p['model_state'], strict=True)
    assert len(model.features) == 11 and model.head.out_channels == 6
    previous = torch.tensor(qat.INPUT_SCALE, dtype=torch.float64)
    layers = []
    with torch.no_grad():
        for i, spec in enumerate(LAYER_SPECS):
            if i < 11:
                w, b = qat.QATSafetyGridNetL._fold_block(model.features[i])
                target = p['activation_scales'][spec.name]
            else:
                w, b = model.head.weight, model.head.bias
                target = qat.FINAL_TARGET_SCALE
            assert tuple(w.shape) == (spec.cout, spec.cin, spec.kernel, spec.kernel)
            q = qat.quantize_folded_parameters_ste(w, b, previous_scale=previous,
                                                  target_output_scale=target, hardsigmoid=i == 11)
            # Reject saturation rather than silently reproducing QAT's clamp.
            unbounded_w = torch.round(w.double() / q.weight_scale)
            unbounded_b = torch.round(b.double() / q.accumulator_scale)
            assert torch.isfinite(unbounded_w).all() and torch.isfinite(unbounded_b).all()
            assert unbounded_w.min() >= -128 and unbounded_w.max() <= 127
            assert unbounded_b.min() >= -(1 << 31) and unbounded_b.max() < (1 << 31)
            assert q.q_bias.min() >= -(1 << 31) and q.q_bias.max() < (1 << 31)
            shift = int(q.shift)
            assert float(q.shift) == shift and 0 <= shift <= 15
            wi = q.q_weight.numpy().astype(np.int8)
            bi = q.q_bias.numpy().astype(np.int32)
            assert np.array_equal(unbounded_w.numpy(), wi)
            assert np.array_equal((unbounded_b + q.hardsigmoid_bias_offset).numpy(), bi)
            # Conservative overflow proof for every possible uint8 input.
            low = np.minimum(wi.astype(np.int64), 0).sum((1, 2, 3)) * 255 + bi
            high = np.maximum(wi.astype(np.int64), 0).sum((1, 2, 3)) * 255 + bi
            assert low.min() >= -(1 << 31) and high.max() < (1 << 31)
            layers.append(dict(weight=wi, bias=bi, shift=shift,
                               input_scale=float(previous), weight_scale=float(q.weight_scale),
                               accumulator_scale=float(q.accumulator_scale), output_scale=float(q.output_scale),
                               activation_range=p['activation_ranges'][spec.name], target_scale=target,
                               hardsigmoid_bias_offset=int(q.hardsigmoid_bias_offset),
                               accumulator_bounds=[int(low.min()), int(high.max())]))
            previous = q.output_scale
    return p, model, layers


def unpack(raw, desc):
    """Independent scalar address decoder based on weight_sdram_dma byte order."""
    layers = []
    end = 0
    assert not any(raw[:desc[5]*4]), 'nonzero prefix'
    for i, spec in enumerate(LAYER_SPECS):
        d = desc[i*8:i*8+8]
        ci, co, k = spec.cin, spec.cout, spec.kernel
        ig, og = (ci+15)//16, (co+15)//16
        assert d[5]*4 >= end and d[6]*4 == d[5]*4+og*ig*256*k*k
        w = np.zeros((co, ci, k, k), np.int8)
        for oc in range(og*16):
            for ic in range(ig*16):
                offset = d[5]*4 + (((oc//16)*ig+ic//16)*256+(ic%16)*16+oc%16)*k*k
                data = np.frombuffer(raw, dtype=np.int8, count=k*k, offset=offset)
                if oc < co and ic < ci:
                    w[oc, ic] = data.reshape(k, k)
                else:
                    assert not data.any(), (i, oc, ic, 'nonzero padded lane')
        bias = np.frombuffer(raw, dtype='<i4', count=og*16, offset=d[6]*4).copy()
        assert not bias[co:].any()
        end = d[6]*4+og*64
        shift = int.from_bytes(raw[end:end+4], 'little')
        assert shift == d[7] and 0 <= shift <= 15
        layers.append(dict(weight=w, bias=bias[:co], shift=shift))
        end += 4
    assert end == len(raw)
    return layers


def compile_bundle(checkpoint, dest, rtl):
    dest.mkdir(parents=True, exist_ok=True)
    original_hash = sha(checkpoint)
    p, model, quant = load_quantized(checkpoint)
    prefix = LOADER_PARAMETER_WORDS - ACTIVE_PARAMETER_WORDS
    assert prefix >= 0
    raw = bytearray(prefix*4)
    desc, records = [], []
    width, height = 160, 120
    for i, (spec, q) in enumerate(zip(LAYER_SPECS, quant)):
        og, ig = (spec.cout+15)//16, (spec.cin+15)//16
        start = len(raw)//4
        padded = np.zeros((og*16, ig*16, spec.kernel, spec.kernel), dtype=np.int8)
        padded[:spec.cout, :spec.cin] = q['weight']
        # [OC group][IC group][IC lane][OC lane][KY][KX], byte zero first.
        packed = padded.reshape(og, 16, ig, 16, spec.kernel, spec.kernel).transpose(0, 2, 3, 1, 4, 5)
        raw.extend(packed.tobytes())
        bstart = len(raw)//4
        bias = np.zeros(og*16, dtype='<i4')
        bias[:spec.cout] = q['bias']
        raw.extend(bias.tobytes())
        shift_addr = len(raw)//4
        raw.extend(q['shift'].to_bytes(4, 'little'))
        ow, oh = (width//2, height//2) if spec.pool else (width, height)
        desc.extend([((1 if i < 11 else 4)<<20) | (0x10000 if i == 11 else 0) |
                     (spec.kernel<<12) | (spec.kernel<<8) | 0x11,
                     (0x122000 if spec.pool else 0) | spec.padding,
                     (spec.cout<<16)|spec.cin, (height<<16)|width, (oh<<16)|ow,
                     start, bstart, q['shift']])
        records.append(dict(layer=i, cin=spec.cin, cout=spec.cout, kernel=spec.kernel, pool=spec.pool,
                            activation=spec.activation, padding=spec.padding, input_hw=[height,width],
                            output_hw=[oh,ow], weight_start=start, bias_start=bstart, shift_addr=shift_addr,
                            end_exclusive=len(raw)//4, weight_count=int(q['weight'].size),
                            weight_min=int(q['weight'].min()), weight_max=int(q['weight'].max()),
                            bias_min=int(q['bias'].min()), bias_max=int(q['bias'].max()),
                            **{k:v for k,v in q.items() if k not in ('weight','bias')}))
        width, height = ow, oh
    assert len(raw) == LOADER_PARAMETER_WORDS*4 and len(raw)%16 == 0
    assert len(raw)//4 <= 1<<17  # also valid with actual 21-bit wrapper
    desc += [0]*(256-len(desc))
    recovered = unpack(raw, desc)
    for i, (a,b) in enumerate(zip(quant,recovered)):
        assert np.array_equal(a['weight'],b['weight']), (i,'weight roundtrip')
        assert np.array_equal(a['bias'],b['bias']), (i,'bias roundtrip')
        assert a['shift'] == b['shift']
    (dest/'npu_params.bin').write_bytes(raw)
    hexfile(dest/'npu_params.hex', np.frombuffer(raw,dtype='<u4'),8)
    hexfile(dest/'npu_desc.hex',desc,8)
    hexfile(dest/'parameters128.hex', [int.from_bytes(raw[j:j+16],'little') for j in range(0,len(raw),16)],32)
    # Re-read the files on disk. This checks the exported HEX32 text and binary,
    # not just the in-memory packing routine.
    disk_desc=[int(v,16) for v in (dest/'npu_desc.hex').read_text().split()]
    disk_raw=b''.join(int(v,16).to_bytes(4,'little') for v in (dest/'npu_params.hex').read_text().split())
    assert disk_raw == (dest/'npu_params.bin').read_bytes() == raw
    assert disk_desc == desc
    disk_layers=unpack(disk_raw,disk_desc)
    for i,(a,b) in enumerate(zip(quant,disk_layers)):
        assert np.array_equal(a['weight'],b['weight']), (i,'exported weight')
        assert np.array_equal(a['bias'],b['bias']), (i,'exported bias')
        assert a['shift'] == b['shift'], (i,'exported shift')
    # Descriptor is a configuration ROM, not a separately Flash-loaded object.
    rom = ['// Person V10 descriptor ROM. Generated by scripts/compiler_person_v10.py (adapted from audited V3 compiler).\n',
           '`ifdef NPU_TEST_MODEL\n`include "npu_test_model_config.vh"\n`else\n',
           f'localparam integer MODEL_LAYER_COUNT = 12;\nlocalparam integer MODEL_PARAMETER_HALFWORDS = {len(raw)//2};\n',
           'localparam integer MODEL_FINAL_WIDTH = 20;\nlocalparam integer MODEL_FINAL_HEIGHT = 15;\nlocalparam integer MODEL_FINAL_CHANNELS = 6;\n',
           'function [31:0] model_descriptor;\ninput [7:0] address;\nbegin\ncase(address)\n']
    rom += [f"8'd{i}: model_descriptor = 32'h{v:08x};\n" for i,v in enumerate(desc[:96])]
    rom += ["default: model_descriptor = 32'd0;\nendcase\nend\nendfunction\n`endif\n"]
    (dest/'npu_model_config.vh').write_text(''.join(rom),encoding='ascii')
    crc = zlib.crc32(raw)
    config = dict(model_id=TOPOLOGY_ID, checkpoint=str(checkpoint), checkpoint_sha256=original_hash,
                  checkpoint_epoch=p['epoch'], qat_recipe=p['qat_recipe'], layer_count=12,
                  input=dict(shape_chw=[3,120,160],layout='CHW',channel_order='RGB',dtype='uint8',
                             bytes_per_frame=57600,active_hw=[90,160],pad_top=15,pad_bottom=15),
                  output=dict(shape_chw=[6,15,20],channels=['OBJ','DX','DY','W','H','PERSON'],
                              obj_threshold=128,person_threshold=128,training_obj_threshold=128,training_person_threshold=128,winner='first row-major maximum OBJ'),
                  image_words=len(raw)//4,active_words=ACTIVE_PARAMETER_WORDS,padding_words=prefix,
                  address_bits_actual=21,address_bits_minimum=17,word_bytes=4,
                  byte_order='little endian',crc32=f'{crc:08x}',
                  flash_parameter_offset='0x200000',flash_parameter_end_exclusive=f'0x{0x200000+len(raw):x}',
                  npu_halfword_base='0xc00000',native_ddr_halfword_base='0x1800000',
                  native_ddr_byte_base='0x3000000',descriptor_contract=dict(image_words=256,active_words=96,
                  storage='npu_model_config.vh compiled into FPGA; boot writes desc_ram[32][8]',
                  flash_address=None,shift_source='descriptor word7[3:0]; image shift words are audit copies'),
                  rtl_project=str(rtl/'td_project/camera_to_dsi_display.al'),layers=records)
    write_json(dest/'deployment.json',config)
    write_json(dest/'quant_config.json',dict(recipe=p['qat_recipe'],activation_ranges=p['activation_ranges'],
              activation_scales=p['activation_scales'],input_scale=qat.INPUT_SCALE,
              final_target_scale=qat.FINAL_TARGET_SCALE,layers=records,roundtrip='PASS: every weight, bias, shift and padded lane'))
    write_json(dest/'compiler_checks.json',dict(result='PASS',layers=12,int8_weights=57368,int32_biases=398,
        shift_words=12,padded_weights_and_biases_zero=True,address_overlap=False,address_overflow=False,
        disk_hex_binary_equal=True,disk_roundtrip_equal=True,checkpoint_unchanged=sha(checkpoint)==original_hash,
        accumulator_bounds_proved_for_all_uint8_inputs=True,
        source_sha256={**{str(Path(__file__).resolve()):sha(__file__)}, **{str(ROOT/name):sha(ROOT/name) for name in ['contract_person.py','model_person.py','qat_person_v4.py']}},
        fp32_checkpoint_sha256=sha(ROOT/'runs/fp32_person_v10_photo_20261024/best.pth')))
    roles={'npu_params.bin':'raw parameter data; U33 offset 0x200000',
           'npu_params.hex':'HEX32 parameter memory, not Intel HEX',
           'npu_desc.hex':'descriptor audit/simulation; no Flash address',
           'parameters128.hex':'simulation loader input',
           'npu_model_config.vh':'descriptor ROM for active RTL',
           'deployment.json':'deployment addresses and contract',
           'quant_config.json':'saved QAT scales and integer parameters',
           'compiler_checks.json':'compiler and exported-file reverse decoding checks'}
    write_json(dest/'bundle_manifest.json',dict(format='person-v10-deployment-manifest-v1',files=[
        dict(path=str(dest/name),size_bytes=(dest/name).stat().st_size,sha256=sha(dest/name),purpose=role)
        for name,role in roles.items()]))
    assert sha(checkpoint) == original_hash
    print(json.dumps(dict(result='PASS',roundtrip_layers=12,weights=sum(q['weight'].size for q in quant),
                         biases=sum(q['bias'].size for q in quant),words=len(raw)//4,prefix_words=prefix,
                         crc32=f'{crc:08x}',shifts=[q['shift'] for q in quant])),flush=True)
    return config


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint',type=Path,default=ROOT/'runs/qat_person_v10_photo_20261024/best_qat.pth')
    parser.add_argument('--dest',type=Path,default=DEFAULT_RTL/'flash/person_v10')
    parser.add_argument('--rtl',type=Path,default=DEFAULT_RTL)
    args=parser.parse_args()
    compile_bundle(args.checkpoint.resolve(),args.dest.resolve(),args.rtl.resolve())
