"""Compile selected V5, make minimal backed-up RTL edits, prepare exact simulation vectors."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import shutil,json,re,hashlib,difflib
import numpy as np
import torch
import torch.nn.functional as F
import compiler_person_v5 as comp
import verify_person_v5_helpers as verify
from contract_person import LAYER_SPECS
from data_person import SafetyYoloDataset
import qat_person_v4 as qat

OUT=comp.DEFAULT_RTL/'flash/person_v5';RTL=comp.DEFAULT_RTL;RUN=OUT/'simulation'

def rounded(n):return ((abs(n)+127)//255)*(1 if n>=0 else -1)

def boxes(win):
    gy,gx,obj,dx,dy,w,h,person=win
    native=[rounded(8*(gx*255+dx)-80*w),rounded(8*(gy*255+dy)-60*h),rounded(8*(gx*255+dx)+80*w),rounded(8*(gy*255+dy)+60*h)]
    hdmi=[rounded(64*(gx*255+dx)-640*w),rounded(64*(gy*255+dy)-480*h)-120,rounded(64*(gx*255+dx)+640*w),rounded(64*(gy*255+dy)+480*h)-120]
    return dict(detected=obj>=64 and person>=32,native=[max(0,min(159 if i%2==0 else 119,v)) for i,v in enumerate(native)],
                hdmi=[max(0,min(1279 if i%2==0 else 719,v)) for i,v in enumerate(hdmi)])

def main():
    torch.set_num_threads(4)
    selection=json.loads((OUT/'selection.json').read_text())
    cfg=comp.compile_bundle(Path(selection['checkpoint']),OUT,RTL)
    cfg['model_variant']='Person V5 geometry_fixed';cfg['acceptance_status']=selection['status']
    comp.write_json(OUT/'deployment.json',cfg)
    changes=[];patch=[]
    updates={'td_project/import/npu_model_config.vh':(OUT/'npu_model_config.vh').read_bytes()}
    for rel in ['user_source/hdl_source/design_top_wrapper.v','td_project/import/npu_u33_mcu_bridge.v']:
        backup=OUT/'original_A'/rel
        old=(backup if backup.exists() else RTL/rel).read_bytes()
        assert old.count(b"32'hd5803b1b")==1,(rel,'unexpected existing CRC')
        updates[rel]=old.replace(b"32'hd5803b1b",f"32'h{cfg['crc32']}".encode())
    for rel,data in updates.items():
        path=RTL/rel;backup=OUT/'original_A'/rel
        if not backup.exists():
            backup.parent.mkdir(parents=True,exist_ok=True);backup.write_bytes(path.read_bytes())
        old=backup.read_bytes()
        assert path.read_bytes() in (old,data),(rel,'unexpected concurrent source edit')
        path.write_bytes(data)
        changes.append(dict(path=str(path),before_sha256=comp.sha(backup),after_sha256=comp.sha(path)))
        patch.extend(difflib.unified_diff(old.decode().replace('\r\n','\n').splitlines(True),data.decode().replace('\r\n','\n').splitlines(True),fromfile='before/'+rel,tofile='after/'+rel))
    (OUT/'rtl_changes.patch').write_text(''.join(patch),encoding='utf-8',newline='\n');comp.write_json(OUT/'rtl_changes.json',changes)
    # Source-only isolated simulation tree; no old work libraries or generated FPGA artifacts.
    for folder in ['td_project/import','td_project/al_ip','user_source/ip_source/w155_d512_fifo','sim/ddr','sim/u33']:
        for path in (RTL/folder).rglob('*'):
            if path.is_file() and path.suffix in ['.v','.vh','.py','.hex'] and not any(x in path.parts for x in ['work','__pycache__','prepared']):
                target=RUN/path.relative_to(RTL);target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
    for rel in ['sim/tb_network12.v','sim/tb_npu_result_overlay.v','sim/tb_npu_bbox_threshold.v','sim/tb_rgb_input.v','sim/tb_rgb_edges.v','sim/run_rgb_input.py','sim/run_rgb_edges.py','sim/run_integer_boundaries.py']:
        src=RTL/rel
        if src.exists():
            target=RUN/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,target)
    for name in ['design_top_wrapper.v','ph1p35_324_ddr_wrapper.v']:
        source=RTL/'user_source/hdl_source'/name
        if source.exists():
            target=RUN/'user_source/hdl_source'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
    comp.write_json(OUT/'simulated_rtl_hashes.json',{str(p.relative_to(RTL)):comp.sha(p) for p in (RTL/'td_project/import').iterdir() if p.suffix in ['.v','.vh']})
    # Existing boot program copies exactly 327680 bytes from 0x20200000 to AHB 0x80000000.
    firmware=RTL/'deployment/npu12/u33_boot_fw.bin';fw=firmware.read_bytes()
    assert len(fw)==40 and comp.sha(firmware)=='f347a854f88361652aba9c80c1bead0ed651d98b4b0e23e88087c5b965f1a33c'
    assert np.frombuffer(fw,dtype='<u4').tolist()==[0x202002b7,0x80000337,0x202503b7,0x0002ae03,0x01c32023,0x00428293,0x00430313,0xfe7298e3,0x0ff0000f,0x0000006f]
    (OUT/'u33_boot_fw.bin').write_bytes(fw)
    comp.write_json(OUT/'firmware_provenance.json',dict(source=str(firmware),sha256=comp.sha(firmware),size_bytes=len(fw),copied_unchanged=True,
        compatibility='same copy size, same XIP parameter source 0x20200000..0x20250000, same AHB destination and reset vector 0x20e00000'))
    p,base,quant=comp.load_quantized(Path(selection['checkpoint']));model=qat.QATSafetyGridNetL(base,p['activation_scales']).eval()
    layers=comp.unpack((OUT/'npu_params.bin').read_bytes(),[int(x,16) for x in (OUT/'npu_desc.hex').read_text().split()])
    evaluation=json.loads((OUT/'evaluation.json').read_text());rows=evaluation['predictions'][selection['variant']]
    dataset=SafetyYoloDataset(evaluation['dataset'],split='valid')
    selected=[]
    for g in ['original','SC500']:
        for positive in [True,False]:
            options=[r for r in rows if r['group']==g and r['positive']==positive and not r['skip']]
            # Positive vector uses labelled localization; negative exercises an actual rejected background.
            options=sorted(options,key=lambda r:((r['obj']>=64 and r['person']>=32)==positive,r['iou'] or 0),reverse=True)
            assert options,(g,positive)
            row=options[0];x=dataset[row['index']][0]
            selected.append((g.lower()+('_person' if positive else '_background'),torch.round(x*255).byte().numpy(),row))
    selected.extend([('zero',np.zeros((3,120,160),np.uint8),'synthetic'),('white_active',np.pad(np.full((3,90,160),255,np.uint8),((0,0),(15,15),(0,0))),'synthetic')])
    ramp=np.zeros((3,120,160),np.uint8);ramp[0,15:105]=np.arange(160,dtype=np.uint8)[None,:];ramp[1,15:105]=np.arange(90,dtype=np.uint8)[:,None];ramp[2,15:105]=255-ramp[0,15:105]
    selected.append(('rgb_ramp',ramp,'synthetic distinct RGB channels'))
    cases=[]
    with torch.inference_mode():
        for name,x,source in selected:
            assert not x[:,:15].any() and not x[:,105:].any()
            folder=OUT/'vectors'/name;folder.mkdir(parents=True,exist_ok=True)
            stages=verify.reference(x,layers)
            actual=torch.round(model(torch.from_numpy(x.copy()).float()[None]/255)*255).byte()[0].permute(2,0,1).numpy()
            assert np.array_equal(actual,stages['O11']),(name,'QAT full output mismatch')
            value=torch.from_numpy(x.copy()).double()[None]
            for i,(spec,q) in enumerate(zip(LAYER_SPECS,quant)):
                accum=qat.integer_conv2d_accumulator(value.float(),torch.from_numpy(q['weight'].copy()).float(),torch.from_numpy(q['bias'].copy()).double(),padding=spec.padding)
                assert np.array_equal(accum[0].numpy(),stages[f'B{i}']),(name,i,'bias accumulator')
                value=(qat.rtl_hardsigmoid_shift_clamp_ste(accum,q['shift']) if i==11 else qat.rtl_relu_shift_clamp_ste(accum,q['shift']))
                assert np.array_equal(value[0].numpy(),stages[f'Q{i}']),(name,i,'quantize')
                if spec.pool:value=F.max_pool2d(value,2,2)
                assert np.array_equal(value[0].numpy(),stages[f'O{i}']),(name,i,'output')
            (folder/'input.bin').write_bytes(x.tobytes());comp.hexfile(folder/'input.hex',x.ravel(),2)
            (folder/'expected_final.bin').write_bytes(stages['O11'].tobytes());np.savez_compressed(folder/'reference.npz',**stages)
            win=verify.winner(actual)
            result=dict(name=name,result='PASS',source=source,winner=win,bbox=boxes(win),max_obj_tied_cells=int(np.count_nonzero(actual[0]==actual[0].max())),
                final_bytes=1800,mismatches=0,max_absolute_error=0,stage_values=sum(v.size for v in stages.values()),input_sha256=comp.sha(folder/'input.bin'))
            cases.append(result);print('PYTHON_EXACT_PASS',name,win,flush=True)
    comp.write_json(OUT/'python_verification.json',dict(result='PASS',cases=cases))
    # Update only isolated testbench CRC expectations and inputs, not active test sources.
    target=RUN/'deployment/npu12';target.mkdir(parents=True,exist_ok=True);shutil.copyfile(OUT/'parameters128.hex',target/'parameters128.hex')
    for tb in (RUN/'sim/u33').glob('tb*.v'):
        s=tb.read_text().replace('f918606b',cfg['crc32']).replace('F918606B',cfg['crc32']).replace('d5803b1b',cfg['crc32'])
        tb.write_text(s,encoding='utf-8')
    print('PREPARED',cfg['crc32'],len(cases),'cases',flush=True)

if __name__=='__main__':main()
