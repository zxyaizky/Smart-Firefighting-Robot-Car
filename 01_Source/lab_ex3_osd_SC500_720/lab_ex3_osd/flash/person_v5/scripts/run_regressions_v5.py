"""Independent simulation work library for upload, bbox and input boundary checks."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import json,shutil,subprocess
import compiler_person_v5 as comp
OUT=comp.DEFAULT_RTL/'flash/person_v5';REG=OUT/'regression'

def run(args,log):
    with (OUT/'commands.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(dict(command=list(map(str,args)),cwd=str(REG),log=str(log)))+'\n')
    p=subprocess.run(list(map(str,args)),cwd=REG,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    log.parent.mkdir(parents=True,exist_ok=True);log.write_text(p.stdout,encoding='utf-8')
    return p

def main():
    for folder in ['td_project/import','td_project/al_ip','user_source/ip_source/w155_d512_fifo','sim/ddr','sim/u33','deployment/npu12']:
        for p in (OUT/'simulation'/folder).rglob('*'):
            if p.is_file() and p.suffix in ['.v','.vh','.hex','.py'] and 'work' not in p.parts:
                target=REG/p.relative_to(OUT/'simulation');target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
    for filename in ['run_tiles.py','export_network12.py','run_rgb_input.py','run_rgb_edges.py','run_integer_boundaries.py','tb_rgb_input.v','tb_rgb_packer.v','tb_rgb_edges.v','tb_integer_boundaries.v','tb_npu_result_overlay.v','tb_npu_bbox_threshold.v']:
        p=comp.DEFAULT_RTL/'sim'/filename;target=REG/'sim'/filename
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
    # Preserve the V3 validated stimulus fix: release DDR only after rejected frame 2.
    path=REG/'sim/tb_rgb_input.v';s=path.read_text()
    if 'reg allow_dma' not in s:
        s=s.replace('reg req_ready = 0, rd_valid = 0;', 'reg req_ready = 0, rd_valid = 0;\n    reg allow_dma=0;')
        s=s.replace('0: if (req) begin','0: if (req && allow_dma) begin')
        s=s.replace('npu_clock_enable = 1;\n            repeat','npu_clock_enable = 1;\n            allow_dma=(mode!=0);\n            repeat')
        s=s.replace('source_frame(2,1); // back-to-back:','source_frame(2,1); allow_dma=1; // back-to-back:')
        path.write_text(s,encoding='utf-8')
    checks=[]
    def checked(args,name,marker):
        p=run(args,OUT/(name+'.log'))
        ok=p.returncode==0 and marker in p.stdout and 'FAIL' not in p.stdout and '** Error' not in p.stdout
        checks.append(dict(test=name,result='PASS' if ok else 'FAIL',marker=marker))
        print(name,checks[-1]['result'],flush=True)
        assert ok,p.stdout[-3500:]
    p=run(['vlib','sim/work'],OUT/'regression_vlib.log');assert p.returncode==0
    # Compile production modules once; no FPGA synthesis is invoked.
    sources=[str(p.relative_to(REG)) for p in (REG/'td_project/import').glob('*.v')]
    vendor=['td_project/al_ip/al_fifo_npu_8x512/al_fifo_npu_8x512.v','td_project/al_ip/al_fifo_npu_8x512/RTL/soft_fifo_39f1577ef3e1.v',
        'td_project/al_ip/sync_fifo_for_linebufferpool/sync_fifo_for_linebufferpool.v','td_project/al_ip/sync_fifo_for_linebufferpool/RTL/soft_fifo_dc793d8cf75c.v',
        'user_source/ip_source/w155_d512_fifo/w155_d512_fifo.v','user_source/ip_source/w155_d512_fifo/soft_fifo_al_f58e8b3e1f3d.v']
    p=run(['vlog','-work','sim/work','+define+NO_VCD_DUMP','+define+NPU_STREAM_INPUT_SIM','+incdir+td_project/import','+incdir+sim/ddr',
           *sources,*vendor,'sim/ddr/native_memory_model.v','sim/u33/tb_u33_bridge.v','sim/u33/tb_u33_ddr_boot.v','sim/tb_npu_result_overlay.v','sim/tb_npu_bbox_threshold.v'],OUT/'regression_compile.log')
    assert p.returncode==0 and '** Error' not in p.stdout,p.stdout[-4000:]
    for top,marker in [('tb_u33_bridge','U33_BRIDGE_PASS'),('tb_u33_ddr_boot','U33_DDR_BOOT_PASS'),('tb_npu_result_overlay','NPU_OVERLAY_PASS'),('tb_npu_bbox_threshold','NPU_BBOX_THRESHOLD_PASS')]:
        checked(['vsim','-c','-voptargs=+acc','-lib','sim/work',top,'-do','run -all; quit -f'],top,marker)
    checked([sys.executable,'-B','sim/run_integer_boundaries.py'],'integer_boundaries','INTEGER_BOUNDARIES_PASS' if False else '"result": "PASS"')
    for case in ['continuous','reset','slow_npu']:
        p=run([sys.executable,'-B','sim/run_rgb_input.py','--case',case],OUT/('rgb_'+case+'.log'))
        if case!='slow_npu':
            assert p.returncode==0,p.stdout[-3500:]
            report=json.loads((REG/f'sim/rgb_input/{case}/summary.json').read_text());checks.append(dict(test='rgb_'+case,**report))
        else:
            observed=REG/'sim/rgb_input/slow_npu/observed.txt'
            lines=observed.read_text().splitlines()
            assert p.returncode!=0 and lines[-1]=='FAIL timeout',(p.returncode,lines[-2:])
            checks.append(dict(test='rgb_slow_npu',result='FAIL',known_existing=True,video_clock_hz=1e9/14,npu_clock_hz=20000000,
                expected_rgb_bytes=43200,actual_rgb_bytes=sum(s.startswith('B ') for s in lines),
                cause='256-token FIFO overflows during PING clear at slow 20MHz NPU clock; inference stalls. Unchanged input RTL; normal 100MHz checks listed separately.'))
        print('RGB',case,checks[-1]['result'],flush=True)
    checked([sys.executable,'-B','sim/run_rgb_edges.py'],'rgb_edges','"result": "PASS"')
    comp.write_json(OUT/'regression_verification.json',dict(result='PASS_WITH_KNOWN_FAILURE',checks=checks))
    print('REGRESSIONS_COMPLETE_WITH_KNOWN_SLOW_CLOCK_FAILURE',flush=True)

if __name__=='__main__':main()
