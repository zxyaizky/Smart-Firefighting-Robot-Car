"""ModelSim RTL regression. Reference uses full-image convolution, never RTL tile logic."""
import argparse
import json
import random
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / 'sim'

CASES = [
    dict(name='tmux_tail_poison', w=6, h=5, ci=17, co=17, k=3, pad=1, pool=1,
         shift=3, gaps=1, reset=0, tail_poison=1),
    dict(name='tmux_tail1', w=5, h=5, ci=17, co=17, k=3, pad=1, pool=0, shift=3, gaps=1, reset=0),
    dict(name='tmux_tail2', w=6, h=5, ci=18, co=18, k=1, pad=0, pool=1, shift=2, gaps=1, reset=0),
    dict(name='tmux_tail15', w=5, h=4, ci=33, co=31, k=3, pad=1, pool=0, shift=4, gaps=1, reset=0),
    dict(name='tmux_cout1', w=3, h=3, ci=1, co=1, k=1, pad=0, pool=0, shift=0, gaps=0, reset=0),
    dict(name='k3_same_cin17', w=7, h=6, ci=17, co=19, k=3, pad=1, pool=0, shift=4, gaps=0, reset=0),
    dict(name='k3_pool_cin33_gaps', w=8, h=7, ci=33, co=19, k=3, pad=1, pool=1, shift=5, gaps=1, reset=0),
    dict(name='k3_valid', w=8, h=7, ci=18, co=16, k=3, pad=0, pool=0, shift=4, gaps=1, reset=0),
    dict(name='k1_cin17', w=7, h=5, ci=17, co=19, k=1, pad=0, pool=0, shift=1, gaps=1, reset=0),
    dict(name='k1_pool_reset', w=7, h=6, ci=17, co=16, k=1, pad=0, pool=1, shift=2, gaps=1, reset=1),
    dict(name='k3_width160', w=160, h=5, ci=17, co=16, k=3, pad=1, pool=1, shift=4, gaps=1, reset=0),
    dict(name='k3_single_pixel', w=1, h=1, ci=17, co=16, k=3, pad=1, pool=0, shift=1, gaps=1, reset=0),
    dict(name='k1_single_cin', w=9, h=5, ci=1, co=16, k=1, pad=0, pool=0, shift=0, gaps=0, reset=0),
    dict(name='k2_same_pool', w=7, h=5, ci=17, co=19, k=2, pad=1, pool=1, shift=3, gaps=1, reset=0),
    dict(name='k2_valid', w=7, h=6, ci=17, co=16, k=2, pad=0, pool=0, shift=3, gaps=0, reset=0),
    dict(name='k3_fifo_reset', w=9, h=7, ci=17, co=19, k=3, pad=1, pool=1, shift=4, gaps=1, reset=1),
    dict(name='k1_tiny_pool', w=2, h=5, ci=1, co=16, k=1, pad=0, pool=1, shift=0, gaps=0, reset=0),
    dict(name='k3_psum32', w=4, h=5, ci=65, co=16, k=3, pad=1, pool=0, shift=15, gaps=1, reset=0, extreme=1),
]

def tool(name):
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f'{name} must be on PATH (ModelSim/Questa)')
    return found

def run(command, logfile):
    p = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    logfile.write_text(p.stdout, encoding='utf-8')
    if p.returncode or '** Error' in p.stdout or '** Fatal' in p.stdout:
        raise RuntimeError(f'Command failed; see {logfile}\n{p.stdout[-5000:]}')
    return p.stdout

def hexfile(path, values, width):
    path.write_text(''.join(f'{v & ((1 << (width*4))-1):0{width}x}\n' for v in values))

def reference(case, directory, input_values=None):
    w,h,ci,co,k = (case[n] for n in ('w','h','ci','co','k'))
    pad = case['pad'] if k != 1 else 0
    rng = random.Random(83721 + w + ci*19 + k)
    inp = input_values if input_values is not None else [rng.randrange(0,32) for _ in range(ci*h*w)]
    weights = [rng.randrange(-3,5) if t < k*k else 0 for _ in range(co*ci) for t in range(9)]
    bias = [rng.randrange(-250,200) for _ in range(co)]
    if case.get('extreme'):
        inp = [255]*len(inp)
        weights = [(-128 if oc % 2 else 127) if t < k*k else 0
                   for oc in range(co) for _ in range(ci) for t in range(9)]
    ow,oh = w+2*pad-k+1,h+2*pad-k+1
    sums, quant = {}, {}
    # Poison inactive lanes with positive nonzero weights/bias. Their public
    # outputs must be masked to zero; optimized RTL may skip their PE rounds, so
    # the internal debug PSUM value of an inactive lane is intentionally don't-care.
    calc_co = ((co+15)//16)*16 if case.get('tail_poison') else co
    for oc in range(calc_co):
        for y in range(oh):
            for x in range(ow):
                v = 0
                for ic in range(ci):
                    for ky in range(k):
                        for kx in range(k):
                            ix,iy = x+kx-pad,y+ky-pad
                            if 0 <= ix < w and 0 <= iy < h:
                                weight = weights[(oc*ci+ic)*9+ky*k+kx] if oc < co else 127
                                v += inp[(ic*h+iy)*w+ix] * weight
                sums[oc,x,y] = v
                bias_value = bias[oc] if oc < co else 10000
                quant[oc,x,y] = min(255,max(0,(v+bias_value) >> case['shift']))
    fw,fh = (ow//2,oh//2) if case['pool'] else (ow,oh)
    expected = {}
    for oc in range(co):
        for y in range(fh):
            for x in range(fw):
                expected[oc,x,y] = max(quant[oc,2*x+dx,2*y+dy] for dy in (0,1) for dx in (0,1)) if case['pool'] else quant[oc,x,y]
    hexfile(directory/'input.hex', inp + [0]*(32768-len(inp)), 2)
    hexfile(directory/'weight.hex', weights + [0]*(65536-len(weights)), 2)
    hexfile(directory/'bias.hex', bias + [0]*(64-len(bias)), 8)
    desc = [0x10100000 | (k<<12) | (k<<8) | 0x11,
            (0x122000 if case['pool'] else 0) | pad,
            (co<<16)|ci, (h<<16)|w, (fh<<16)|fw,
            case.get('weight_base',0), case.get('bias_base',0x10000), case['shift']]
    hexfile(directory/'desc.hex', desc, 8)
    return sums,expected,ow,oh,fw,fh

def check(case, directory, ref):
    sums,expected,ow,oh,fw,fh = ref
    text = (directory/'observed.txt').read_text()
    if case['reset']:
        assert 'RESET\n' in text, 'reset did not execute'
        text = text.split('RESET\n')[-1]
    assert 'FAIL' not in text and 'PASS ' in text, text[-3000:]
    seen,ps_seen,requests = set(),set(),[]
    count = 0
    for line in text.splitlines():
        fields = line.split()
        if fields[0] == 'D':
            requests.append(tuple(map(int,fields[1:])))
        if fields[0] not in ('O','P'): continue
        kind = fields[0]
        group,x,y = map(int,fields[1:4])
        if kind == 'O':
            addr = int(fields[4]); data = int(fields[5],16); bits = 8
            assert addr == group*fw*fh+y*fw+x, f'write address {line}'
            assert 0 <= x < fw and 0 <= y < fh, f'output coord {line}'
            count += 1
        else:
            data = int(fields[4],16); bits = 32
            assert 0 <= x < ow and 0 <= y < oh, f'psum coord {line}'
        for lane in range(16):
            oc = group*16+lane
            key = oc,x,y
            value = (data>>(lane*bits)) & ((1<<bits)-1)
            if kind == 'P' and value >= 2**31: value -= 2**32
            gold = (expected if kind == 'O' else sums).get(key,0)
            if not (kind == 'P' and oc >= case['co']):
                assert value == gold, f'{kind} {key}: RTL={value} reference={gold}'
            seen_set = seen if kind == 'O' else ps_seen
            assert key not in seen_set, f'duplicate {kind} {key}'
            seen_set.add(key)
    groups = (case['co']+15)//16
    cin_groups = (case['ci']+15)//16
    expected_dma = [(oc,y,c,case.get('weight_base',0)+(oc*cin_groups+c)*64*case['k']**2,
                     case.get('bias_base',0x10000)+oc*16,
                     4*min(16,case['ci']-c*16)*case['k']**2)
                    for oc in range(groups) for y in range(0,oh,2) for c in range(cin_groups)
                    if cin_groups != 1 or y == 0]
    assert requests == expected_dma, f'DMA/order mismatch: {requests[:12]} versus {expected_dma[:12]}'
    assert len(seen) == groups*16*fw*fh, (len(seen), groups*16*fw*fh)
    assert len(ps_seen) == groups*16*ow*oh, (len(ps_seen), groups*16*ow*oh)
    trailer = text.splitlines()[-1].split()
    assert list(map(int,trailer[1:])) == [count,groups*((oh+1)//2),len(expected_dma)], trailer
    return dict(case=case['name'], result='PASS', output_vectors=count,
                checked_output_lanes=len(seen), checked_psum_lanes=len(ps_seen),
                tiles=groups*((oh+1)//2), dma_requests=len(requests))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--case', default='all', choices=['all']+[c['name'] for c in CASES])
    parser.add_argument('--no-compile', action='store_true')
    args = parser.parse_args()
    if not args.no_compile:
        if not (SIM/'work').exists(): run([tool('vlib'), 'sim/work'],SIM/'vlib.log')
        # Shared TD project resource: never regenerate or overwrite microcode.
        rom_path = ROOT/'td_project/import/microcode_words.hex'
        if not rom_path.is_file():
            raise FileNotFoundError(rom_path)
        sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT/'td_project/import').glob('*.v'))
        vendor = ['td_project/al_ip/al_fifo_npu_8x512/al_fifo_npu_8x512.v',
                  'td_project/al_ip/al_fifo_npu_8x512/RTL/soft_fifo_39f1577ef3e1.v',
                  'td_project/al_ip/sync_fifo_for_linebufferpool/sync_fifo_for_linebufferpool.v',
                  'td_project/al_ip/sync_fifo_for_linebufferpool/RTL/soft_fifo_dc793d8cf75c.v']
        run([tool('vlog'),'-work','sim/work','+define+NO_VCD_DUMP','+incdir+td_project/import',
             '+define+MICROCODE_FILE="td_project/import/microcode_words.hex"',
             *sources,*vendor,'sim/tb_npu_tiles.v'],SIM/'compile.log')
    results = []
    for case in CASES:
        if args.case not in ('all',case['name']): continue
        directory = SIM/'results'/case['name']
        directory.mkdir(parents=True,exist_ok=True)
        ref = reference(case,directory)
        flags = [f'+{key.upper()}={value}' for key,value in case.items() if key != 'name']
        out = run([tool('vsim'),'-c','-suppress','2685,2718','-voptargs=+acc','-lib','sim/work',
                   'tb_npu_tiles',f'+DIR=sim/results/{case["name"]}',*flags,
                   '-do','run -all; quit -f'],directory/'simulation.log')
        result = check(case,directory,ref)
        print(json.dumps(result),flush=True)
        results.append(result)
    (SIM/'results'/('summary.json' if args.case == 'all' else args.case+'.json')).write_text(json.dumps(results,indent=2))

if __name__ == '__main__': main()
