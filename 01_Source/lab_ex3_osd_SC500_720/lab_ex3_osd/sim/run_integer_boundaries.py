"""Exact Python-wide-integer activation/quantization boundary vectors."""
import json
from pathlib import Path
from run_tiles import tool,run
from export_network12 import DEST


def main():
    vectors=[]
    for activation in (0,1,2):
        for shift in range(16):
            values={-(1<<31),-(1<<31)+1,(1<<31)-1,(1<<31)-2,
                    -200000001,-200000000,200000000,200000001,-4,-3,-2,-1,0,1,2,3,4}
            for boundary in (0,1,254,255,256):
                value=boundary<<shift
                values.update(value+d for d in (-1,0,1))
                preimage=(value*256)//43-3
                values.update(preimage+d for d in (-2,-1,0,1,2))
            for value in sorted(values):
                if not -(1<<31)<=value<(1<<31): continue
                act=max(value,0) if activation==0 else (((value+3)*43)>>8 if activation==1 else value)
                q=min(255,max(0,act>>shift))
                vectors.append(((activation<<4|shift)<<72)|((value&0xffffffff)<<40)|
                               ((act&0xffffffff)<<8)|q)
    DEST.mkdir(exist_ok=True)
    (DEST/'boundaries.hex').write_text(''.join(f'{v:020x}\n' for v in vectors))
    run([tool('vlog'),'-work','sim/work','td_project/import/activation_single.v',
         'td_project/import/quantize_single.v','sim/tb_integer_boundaries.v'],DEST/'boundary_compile.log')
    out=run([tool('vsim'),'-c','-lib','sim/work','tb_integer_boundaries',f'+COUNT={len(vectors)}',
             '-do','run -all; quit -f'],DEST/'boundary_simulation.log')
    assert 'INTEGER_BOUNDARIES_PASS' in out and 'FAIL' not in out,out[-1000:]
    report=dict(result='PASS',vectors=len(vectors),shifts=list(range(16)),
                activations=['relu','integer_hardsigmoid','identity'],
                covers=['INT32 extrema','old 33-bit overflow','negative arithmetic shifts',
                        'quantization 0/1/254/255/256 boundaries','pipeline reset'])
    (DEST/'boundaries.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report))


if __name__=='__main__': main()
