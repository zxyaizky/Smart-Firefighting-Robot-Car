"""Read-only V5 FP32/initial-QAT/best-QAT validation and full-byte comparison."""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import hashlib,json
import numpy as np
import torch
import compiler_person_v5 as comp
from data_person import SafetyYoloDataset
from model_person import load_training_state
from grid_person import probabilities_to_bytes,decode_grid_bytes,xywh_iou,FixedThresholdMetrics
import qat_person_v4 as qat

OUT=comp.DEFAULT_RTL/'flash/person_v5'
DATASET=Path(r'C:\Users\lx292\Desktop\Safety_Dataset\person_v5_geometry_fixed')
GATES=[(128,128),(96,64),(64,32)]

def group(name):
    if name.startswith('camera_'):return 'SC500'
    assert name.startswith('original_'),name
    return 'original'

def metrics(rows,og,pg):
    rows=[r for r in rows if not r['skip']]
    pos=[r for r in rows if r['positive']];neg=[r for r in rows if not r['positive']]
    passed=lambda r:r['obj']>=og and r['person']>=pg
    hits=sum(passed(r) for r in pos);localized=sum(passed(r) and r['iou']>=.5 for r in pos)
    fp=sum(passed(r) for r in neg)
    return dict(positives=len(pos),negatives=len(neg),detected_positive=hits,positive_iou50_count=localized,
        positive_iou50_percent=100*localized/len(pos) if pos else None,false_positives=fp,
        negative_rejection_percent=100*(len(neg)-fp)/len(neg) if neg else None)

def main():
    torch.set_num_threads(4)
    paths={k:comp.ROOT/p for k,p in dict(fp32='runs/fp32_person_v5_geometry_fixed/best.pth',initial='runs/qat_person_v5/initial_qat.pth',best='runs/qat_person_v5/best_qat.pth').items()}
    hashes={k:comp.sha(p) for k,p in paths.items()}
    states={};models={};quantized={}
    for name,path in paths.items():
        if name=='fp32':
            states[name]=torch.load(path,map_location='cpu',weights_only=False)
            models[name]=load_training_state(states[name]).eval()
        else:
            p,base,q=comp.load_quantized(path)
            states[name]=p;models[name]=qat.QATSafetyGridNetL(base,p['activation_scales']).eval();quantized[name]=q
    dataset=SafetyYoloDataset(DATASET,split='valid')
    predictions={k:[] for k in paths};official={k:FixedThresholdMetrics() for k in paths}
    byte_diff=dict(validation_bytes=0,validation_changed=0,validation_frames_changed=0,raw_capture_bytes=0,raw_capture_changed=0,raw_capture_frames_changed=0,max_abs=0)
    samples=[]
    with torch.inference_mode():
        for index,record in enumerate(dataset.records):
            x,target,mask,ignore=dataset[index]
            assert tuple(x.shape)==(3,120,160) and not x[:,:15].any() and not x[:,105:].any()
            if group(record.image.name)=='SC500':
                from PIL import Image
                assert Image.open(record.image).size==(160,90),('camera must be unpadded content',record.image)
            bytes_out={}
            for name,model in models.items():
                output=model(x[None]);b=probabilities_to_bytes(output);bytes_out[name]=b.numpy()
                dec=decode_grid_bytes(b)[0].float();positive=bool(target[0]>.5)
                iou=float(xywh_iou(dec[None,1:5]/255,target[None,1:5])[0]) if positive else None
                gy,gx=divmod(int(b[0,:,:,0].reshape(-1).argmax()),20)
                win=[gy,gx,*map(int,b[0,gy,gx].tolist())]
                predictions[name].append(dict(index=index,image=str(record.image),label=str(record.label),group=group(record.image.name),positive=positive,
                    skip=not positive and bool(ignore.any()),obj=int(dec[0]),person=int(dec[5]),iou=iou,winner=win))
                official[name].update(output,target[None],ignore[None])
            delta=np.abs(bytes_out['best'].astype(np.int16)-bytes_out['initial'].astype(np.int16))
            byte_diff['validation_bytes']+=delta.size;byte_diff['validation_changed']+=int(np.count_nonzero(delta))
            byte_diff['validation_frames_changed']+=bool(delta.any());byte_diff['max_abs']=max(byte_diff['max_abs'],int(delta.max()))
        capture=Path(r'C:\Users\lx292\Desktop\qiansai_last\ethernet_host\captures\person_ready_20261015_222017')
        raw_pass={k:{f'{o}/{p}':0 for o,p in GATES} for k in paths}
        for f in sorted(capture.glob('frame_*.rgb')):
            a=np.frombuffer(f.read_bytes(),dtype=np.uint8).reshape(120,160,3)
            x=torch.from_numpy(a.transpose(2,0,1).copy()).float()[None]/255
            outputs={}
            for name,model in models.items():
                b=probabilities_to_bytes(model(x));outputs[name]=b.numpy()
                dec=decode_grid_bytes(b)[0]
                for og,pg in GATES:raw_pass[name][f'{og}/{pg}']+=int(dec[0]>=og and dec[5]>=pg)
            delta=np.abs(outputs['best'].astype(np.int16)-outputs['initial'].astype(np.int16))
            byte_diff['raw_capture_bytes']+=delta.size;byte_diff['raw_capture_changed']+=int(np.count_nonzero(delta))
            byte_diff['raw_capture_frames_changed']+=bool(delta.any());byte_diff['max_abs']=max(byte_diff['max_abs'],int(delta.max()))
    summary={name:{g:{f'{o}/{p}':metrics([r for r in rows if g=='all' or r['group']==g],o,p) for o,p in GATES} for g in ['SC500','original','all']} for name,rows in predictions.items()}
    # Prefer measured SC500 localization/false-positive behavior, then original data.
    def quality(name):
        s=summary[name]
        return tuple(value for gate in ['64/32','96/64','128/128'] for g in ['SC500','original']
                     for value in (s[g][gate]['positive_iou50_count'],-s[g][gate]['false_positives']))
    selected='best' if quality('best')>=quality('initial') else 'initial'
    exact_same=byte_diff['validation_changed']==0 and byte_diff['raw_capture_changed']==0
    reason=('Initial and best outputs are byte-identical on all evaluated inputs; use best by user rule.' if exact_same else
            'Compared SC500 localization and false alarms at all requested gates, then original validation; best wins ties. Full byte differences are reported separately.')
    report=dict(result='PASS',dataset=str(DATASET),validation_samples=len(dataset),test_split_read=False,paths={k:str(p) for k,p in paths.items()},sha256=hashes,
        checkpoint_epochs={k:states[k].get('epoch') for k in states},metrics=summary,official_128={k:v.compute() for k,v in official.items()},
        initial_best_output_differences=byte_diff,raw_300_gate_pass=raw_pass,selected=selected,selection_reason=reason,
        status='EXPERIMENTAL_CANDIDATE_NOT_BOARD_ACCEPTED',predictions=predictions,
        missing_requested_script='compare_person_fp32_qat_v5.py does not exist; this independent adapter evaluates the same dataset/byte reducer without modifying Python project.')
    comp.write_json(OUT/'evaluation.json',report)
    comp.write_json(OUT/'selection.json',dict(checkpoint=str(paths[selected]),sha256=hashes[selected],variant=selected,reason=reason,status=report['status']))
    for name,path in paths.items():assert comp.sha(path)==hashes[name]
    print(json.dumps(dict(selected=selected,byte_differences=byte_diff,metrics=summary),indent=2),flush=True)

if __name__=='__main__':main()
