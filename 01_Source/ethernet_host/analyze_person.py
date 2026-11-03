"""Analyze one exact RGB888 capture with the existing Person V3 QAT checkpoint.

Executed by the user's PyTorch Python, independently from the packaged viewer.
Never writes the model, parameters, project, or FPGA.
"""
import argparse
import json
from pathlib import Path
import sys


def model_input(data):
    import numpy as np
    if len(data) == 160 * 120 * 3:
        return np.frombuffer(data, dtype=np.uint8).reshape(120, 160, 3), False
    if len(data) != 640 * 360 * 3:
        raise ValueError('输入必须是160×120或640×360的RGB888保存帧')
    # Same 0,8,... source sampling phase as the FPGA NPU, through 2x video.
    # RGB565 already discarded color bits; these are approximate PC scores.
    image = np.zeros((120, 160, 3), dtype=np.uint8)
    image[15:105] = np.frombuffer(data, dtype=np.uint8).reshape(360, 640, 3)[::4, ::4]
    return image, True


def main():
    parser=argparse.ArgumentParser();parser.add_argument('rgb',type=Path)
    parser.add_argument('--model-dir',type=Path,required=True);args=parser.parse_args()
    data=args.rgb.read_bytes()
    image, reconstructed = model_input(data)
    sys.path.insert(0,str(args.model_dir.resolve()))
    import torch
    import numpy as np
    import compiler_person_v3 as compiler
    import qat_person_v3 as qat
    torch.set_num_threads(4)
    checkpoint=args.model_dir/'runs/qat_person_v3/best_qat.pth'
    p,model,_=compiler.load_quantized(checkpoint)
    qat_model=qat.QATSafetyGridNetL(model,p['activation_scales']).eval()
    tensor=torch.from_numpy(image.transpose(2,0,1).copy()).float().div_(255).unsqueeze(0)
    with torch.inference_mode():
        output=torch.round(qat_model(tensor)*255).clamp(0,255).to(torch.uint8)[0].cpu()
    if tuple(output.shape)!=(15,20,6):raise ValueError(f'人体模型输出形状异常：{tuple(output.shape)}')
    index=int(torch.argmax(output[:,:,0].reshape(-1)));gy,gx=divmod(index,20)
    obj,dx,dy,w,h,person=[int(v) for v in output[gy,gx].tolist()]
    result=dict(source='PC Person V3 QAT evaluation, not FPGA-measured scores',
                input=str(args.rgb),checkpoint=str(checkpoint),
                rgb565_reconstruction=reconstructed,
                comparison='approximate: RGB565 color loss, 4x sampling and letterbox' if reconstructed else 'original 160x120 network pixels',
                winner=dict(gy=gy,gx=gx,obj=obj,dx=dx,dy=dy,w=w,h=h,person=person),
                detected=obj>=128 and person>=128,
                top_padding_nonzero=int(np.count_nonzero(image[:15])),
                bottom_padding_nonzero=int(np.count_nonzero(image[105:])))
    print('RESULT '+json.dumps(result,ensure_ascii=True),flush=True)


if __name__=='__main__':main()
