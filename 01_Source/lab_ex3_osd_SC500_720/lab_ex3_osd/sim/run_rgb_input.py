"""Independent, full-size phase-aligned RGB reference + actual NPU RTL regression.

No DUT coordinates or address expressions are used to construct the reference.
The reference materializes 3 complete output planes, then visits mathematical
convolution halo rectangles to check the BCU's physical requests and responses.
"""
import argparse
import json
from pathlib import Path
from run_tiles import ROOT, SIM, tool, run, hexfile

DEST = SIM / 'rgb_input'


def reference(frame_id):
    image = bytearray(57600)
    for y in range(90):
        sy = 8*y
        for x in range(160):
            sx = 8*x
            rgb = ((sx*7+sy*13+frame_id*29+(sx//256)*31) & 255,
                   (sx*11+sy*3+frame_id*47+(sy//256)*17) & 255,
                   ((sx ^ (sy*5))+frame_id*61+sx//16) & 255)
            for c, value in enumerate(rgb):
                image[c*19200+(y+15)*160+x] = value
    return image


def read_order(image):
    requests, responses = [], []
    for tile_y in range(0,120,2):
        for c in range(3):
            for y in range(tile_y-1,tile_y+3):
                for x in range(-1,161):
                    inside = 0 <= x < 160 and 0 <= y < 120
                    offset = c*19200+y*160+x
                    if inside:
                        requests.append(divmod(offset,16))
                    responses.append((image[offset] if inside else 0, int(c==0), int(c==2)))
    return requests, responses


def check(directory, mode):
    # Expected selection is prescribed by the external stimulus, including reset
    # epochs and deliberately rejected frame IDs. It is not learned from the DUT.
    selected = {1: [1,4]} if mode == 0 else {2:[7],4:[9],5:[10]}
    seq = {e:0 for e in selected}
    current = {}
    completed, snapshots, checked_bytes, read_count, response_count = 0,0,0,0,0
    memory_seen = {}
    for line in (directory/'observed.txt').open():
        f = line.split()
        assert f[0] != 'FAIL', line
        if f[0] == 'T':
            _,epoch,n,x,y=map(int,['0',*f[1:]])
            assert (x,y)==(8*(n%160),8*(n//160)), line
            continue
        if f[0] in ('S','Z'):
            continue
        if f[0] == 'A':
            e, frame_id = map(int, f[1:])
            current[e] = dict(b=0,w=0,r=0,v=0,l=False,id=frame_id,
                              image=reference(frame_id))
            continue
        if f[0] == 'PASS':
            assert tuple(map(int,f[1:])) == ((2,2) if mode==0 else (2,1)), f
            continue
        e = int(f[1])
        assert e in current, f'output without admitted frame in epoch {e}: {line}'
        st = current[e]
        image = st['image']
        if f[0] == 'B':
            addr, value = int(f[2]), int(f[3],16)
            sample, channel = divmod(st['b'], 3)
            y, x = divmod(sample, 160)
            expected = image[channel*19200+(y+15)*160+x]
            assert addr == st['b'] and value == expected, (line, expected)
            st['b'] += 1
            checked_bytes += 1
        elif f[0] == 'W':
            addr, mask, data = int(f[2]),int(f[3],16),int(f[4],16)
            if st['w'] < 3600:
                assert addr == st['w'] and mask == 65535 and data == 0, line
            else:
                stream_index = st['w'] - 3600
                word, channel = divmod(stream_index, 3)
                expected_addr = (150,1350,2550)[channel] + word
                offset = channel*19200 + 15*160 + word*16
                expected_word = int.from_bytes(image[offset:offset+16], 'little')
                assert addr == expected_addr and mask == 65535, line
                assert data == expected_word, line
            st['w'] += 1
        elif f[0] == 'M':
            addr, value = int(f[2]), int(f[3],16)
            seen = memory_seen.setdefault((e,st['id']),set())
            assert addr not in seen and value == image[addr], (line,image[addr])
            seen.add(addr)
        elif f[0] == 'L':
            assert st['b'] == 43200 and st['w'] == 6300 and not st['l'], st
            st['l'] = True
            snapshots += 1
        elif f[0] in ('R','V'):
            assert st['l'], line
            if 'order' not in st:
                st['order'] = read_order(image)
            kind = f[0].lower()
            expected = st['order'][0 if kind=='r' else 1][st[kind]]
            observed = tuple(map(int,f[2:])) if kind=='r' else (int(f[2],16),int(f[3]),int(f[4]))
            assert observed == expected, (line, st[kind], expected)
            st[kind] += 1
            if kind == 'r': read_count += 1
            else: response_count += 1
        elif f[0] == 'D':
            assert st['l'] and st['r'] == len(st['order'][0]) and st['v'] == len(st['order'][1]), st
            assert e in selected and st['id'] == selected[e][seq[e]], st
            assert len(memory_seen[e,st['id']]) == 57600
            seq[e] += 1
            completed += 1
            del current[e]
        else:
            raise AssertionError(line)
    assert completed == (2 if mode==0 else 1), completed
    assert snapshots == 2, snapshots
    for seen in memory_seen.values():
        assert len(seen) == 57600
    if mode:
        assert 0 < current[2]['b'] < 43200 and not current[2]['l'], current[2]
        assert current[4]['l'] and current[4]['r'] > 0, current[4]
    return dict(result='PASS',mode=mode,completed_inferences=completed,
                full_57600_byte_ping_snapshots=snapshots,stream_bytes_checked=checked_bytes,
                physical_reads_checked=read_count,halo_responses_checked=response_count)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--no-compile',action='store_true')
    parser.add_argument('--case',choices=['all','continuous','reset','slow_npu'],default='all')
    args=parser.parse_args()
    DEST.mkdir(exist_ok=True)
    if not args.no_compile:
        if not (SIM/'work').exists():
            run([tool('vlib'),'sim/work'],DEST/'vlib.log')
        sources=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'td_project/import').glob('*.v'))
        vendor=['td_project/al_ip/al_fifo_npu_8x512/al_fifo_npu_8x512.v',
                'td_project/al_ip/al_fifo_npu_8x512/RTL/soft_fifo_39f1577ef3e1.v',
                'td_project/al_ip/sync_fifo_for_linebufferpool/sync_fifo_for_linebufferpool.v',
                'td_project/al_ip/sync_fifo_for_linebufferpool/RTL/soft_fifo_dc793d8cf75c.v']
        run([tool('vlog'),'-work','sim/work','+define+NO_VCD_DUMP','+incdir+td_project/import',
             '+define+NPU_STREAM_INPUT_SIM',
             '+define+MICROCODE_FILE="td_project/import/microcode_words.hex"',
             *sources,*vendor,'sim/tb_rgb_input.v','sim/tb_rgb_packer.v'],DEST/'compile.log')
    packer_output=run([tool('vsim'),'-c','-lib','sim/work','tb_rgb_packer',
                       '-do','run -all; quit -f'],DEST/'packer.log')
    assert 'RGB_PACKER_PASS' in packer_output and 'FAIL' not in packer_output
    results=[]
    for name,mode,vhalf,nhalf in [('continuous',0,7,5),('reset',1,7,5),('slow_npu',0,7,25)]:
        if args.case not in ('all',name):
            continue
        directory=DEST/name
        directory.mkdir(exist_ok=True)
        hexfile(directory/'desc.hex',[0x10103311,0x122001,0x10003,
                (120<<16)|160,(60<<16)|80,0,0x10000,0],8)
        run([tool('vsim'),'-c','-suppress','2685,2718','-voptargs=+acc','-lib','sim/work',
             'tb_rgb_input',f'+DIR=sim/rgb_input/{name}',f'+MODE={mode}',
             f'+VHALF={vhalf}',f'+NHALF={nhalf}','-do','run -all; quit -f'],directory/'simulation.log')
        result=check(directory,mode)
        result['case']=name
        (directory/'summary.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result),flush=True)
        results.append(result)
    (DEST/('summary.json' if args.case=='all' else args.case+'.json')).write_text(json.dumps(results,indent=2))


if __name__ == '__main__':
    main()
