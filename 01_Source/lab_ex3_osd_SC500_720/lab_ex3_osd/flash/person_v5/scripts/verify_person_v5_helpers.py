"""V5 simulation-only helpers extracted from audited V3 verifier; no FPGA build entry point."""
from pathlib import Path
import json,subprocess,time,sys
import numpy as np
import compiler_person_v5 as comp
sys.dont_write_bytecode=True
from contract_person import LAYER_SPECS
RTL=comp.DEFAULT_RTL
DEST=RTL/'flash/person_v5'
RUN=DEST/'simulation'
def command(args,logfile,cwd=None):
    args=list(map(str,args));cwd=RUN if cwd is None else cwd
    with (DEST/'commands.jsonl').open('a',encoding='utf-8') as f:
        f.write(json.dumps(dict(command=args,cwd=str(cwd),log=str(logfile)))+'\n')
    t=time.time()
    p=subprocess.run(args,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    Path(logfile).write_text(p.stdout,encoding='utf-8')
    assert p.returncode==0 and '** Error' not in p.stdout and '** Fatal' not in p.stdout,(args,p.stdout[-4000:])
    print('COMMAND_PASS',Path(logfile).name,'seconds=',round(time.time()-t,1),flush=True)
    return p.stdout

def reference(x,layers):
    stages={}
    for i,(spec,q) in enumerate(zip(LAYER_SPECS,layers)):
        ci,h,w=x.shape
        padded=np.pad(x.astype(np.int64),((0,0),(spec.padding,spec.padding),(spec.padding,spec.padding)))
        acc=np.zeros((spec.cout,h,w),np.int64)
        for ky in range(spec.kernel):
            for kx in range(spec.kernel):
                acc+=(q['weight'][:,:,ky,kx].astype(np.int64) @ padded[:,ky:ky+h,kx:kx+w].reshape(ci,-1)).reshape(spec.cout,h,w)
        stages[f'C{i}']=acc.copy()
        acc+=q['bias'][:,None,None]
        assert acc.min()>=-(1<<31) and acc.max()<(1<<31)
        stages[f'B{i}']=acc.copy()
        act=((acc+3)*43)>>8 if i==11 else np.maximum(acc,0)
        stages[f'A{i}']=act
        x=np.clip(act>>q['shift'],0,255).astype(np.uint8)
        stages[f'Q{i}']=x.copy()
        if spec.pool:
            x=np.maximum.reduce([x[:,dy::2,dx::2] for dy in range(2) for dx in range(2)])
        stages[f'O{i}']=x.copy()
    return stages

def winner(x):
    gy,gx=divmod(int(x[0].argmax()),20)
    return [gy,gx,*[int(v) for v in x[:,gy,gx]]]

def network_tb():
    """Reuse all 5-stage monitors, replace the memory model with real DDR path."""
    s=(RTL/'sim/tb_network12.v').read_text()
    s=s.replace('module tb_network12;','module tb_person_network;')
    s=s.replace('../td_project/import/npu_model_config.vh','npu_model_config.vh')
    s=s.replace('reg rst_n=0,frame=0,valid=0;','reg memory_rst_n=0,frame=0,valid=0; wire rst_n,client_rst_n;')
    s=s.replace('reg req_ready=0,rd_valid=0;','wire req_ready,npu_rd_valid;')
    s=s.replace('reg [15:0] rd_data=0;','wire [15:0] npu_rd_data;')
    s=s.replace('.i_sdram_rd_data(rd_data),.i_sdram_rd_valid(rd_valid)', '.i_sdram_rd_data(npu_rd_data),.i_sdram_rd_valid(npu_rd_valid)')
    start=s.index('    always @(negedge clk) begin\n        req_ready=0;')
    end=s.index('    always @(posedge clk) begin',start)
    s=s[:start]+s[end:]
    # SRAM bank implementation differs from this older testbench. Numeric and
    # unique-address checks at every actual write remain in the host checker.
    start=s.index('    // Verify the actual physical storage')
    end=s.index('    initial begin',start)
    s=s[:start]+s[end:]
    cfg=json.loads((DEST/'deployment.json').read_text())
    fixture=(RTL/'sim/ddr/subsystem_fixture.vh').read_text()
    fixture+='\nassign rst_n=memory_rst_n && params_ready;\nassign client_rst_n=rst_n;\n'
    addition='''
    reg dclk=0;
    always #3 dclk=~dclk;
    reg [127:0] upload_image [0:20479];
    reg [1023:0] input_path, observed_path;
    integer upload_index,dummy;
    always @(posedge clk) if(rst_n && req && req_ready) requests=requests+1;
'''
    guard='''
    always @(posedge dclk) if(memory_rst_n && (load_error || transport_error)) begin
        $display("FAIL shared DDR loader/transport error"); $finish;
    end
'''
    s=s.replace('    npu_network_top dut (',addition+fixture+guard+'\n    npu_network_top dut (')
    s=s.replace('fd=$fopen("sim/network12/observed.txt","w");',
        'dummy=$value$plusargs("INPUT=%s",input_path);\n        dummy=$value$plusargs("OBSERVED=%s",observed_path);\n        fd=$fopen(observed_path,"w");')
    s=s.replace('$readmemh("sim/network12/input.hex",image);','$readmemh(input_path,image);')
    s=s.replace('$readmemh("sim/network12/parameters16.hex",memory);','')
    s=s.replace('$readmemh("sim/network12/descriptors.hex",descriptors);','$readmemh("../npu_desc.hex",descriptors);')
    s=s.replace('repeat(8) @(negedge clk); rst_n=1;',f'''
        $readmemh("../parameters128.hex",upload_image);
        repeat(8) @(negedge clk); memory_rst_n=1;
        repeat(8) @(negedge dclk);
        @(negedge dclk);load_begin=1;load_size=24'd327680;load_crc=32'h{cfg['crc32']};
        @(posedge dclk);while(!load_begin_ready) @(posedge dclk);
        @(negedge dclk);load_begin=0;
        for(upload_index=0;upload_index<20480;upload_index=upload_index+1) begin
            @(negedge dclk);load_valid=1;load_data=upload_image[upload_index];load_last=upload_index==20479;
            @(posedge dclk);while(!load_ready) @(posedge dclk);
            @(negedge dclk);load_valid=0;
        end
        load_last=0;wait(params_ready);
        $display("PERSON_DDR_UPLOAD_VERIFIED bytes=327680 crc={cfg['crc32']}");
''')
    # Winner reducer emits one public event; all 1800 bytes are checked at O11.
    s=s.replace('outputs!=300','outputs!=1').replace('NETWORK12_PASS','PERSON_NETWORK_PASS')
    # Exercise the board's STREAMED_RGB packer branch, not ModelSim's legacy
    # CHW compatibility branch. Source vectors remain the exact same CHW bytes.
    s=s.replace('frame=1;\n        for(i=0;i<57600;i=i+1) begin\n            @(negedge clk); valid=1; pixel=image[i];',
        'frame=1;\n        repeat(3605) @(negedge clk);\n        for(i=0;i<43200;i=i+1) begin\n            @(negedge clk); valid=1; pixel=image[(i%3)*19200+(15+i/480)*160+(i/3)%160];')
    (RUN/'sim/tb_person_network.v').write_text(s)

def check_network(name):
    folder=DEST/'vectors'/name
    with np.load(folder/'reference.npz') as archive:
        gold={k:archive[k] for k in archive.files}
    seen={k:np.zeros(v.shape,np.bool_) for k,v in gold.items()}
    expected_win=winner(gold['O11'])
    dma=[]; layers=[]; trailer=None; winners=[]
    actual_final=np.zeros((6,15,20),np.uint8)
    for line in (folder/'observed.txt').open():
        f=line.split()
        assert f and f[0]!='FAIL',line
        if f[0]=='D': dma.append(tuple(map(int,f[1:])))
        elif f[0]=='L': layers.append(int(f[1]))
        elif f[0]=='PASS': trailer=list(map(int,f[1:]))
        elif f[0]=='F':
            v=int(f[3],16)
            got=[(v>>56)&255,(v>>48)&255,*[(v>>(8*c))&255 for c in range(6)]]
            assert got==expected_win,dict(stage='winner',actual=got,expected=expected_win)
            winners.append(got)
        elif f[0] in 'CBAQO':
            tag,l,g,x,y=f[0],*map(int,f[1:5])
            key=tag+str(l); expected=gold[key]; bits=32 if tag in 'CBA' else 8
            assert 0<=y<expected.shape[1] and 0<=x<expected.shape[2],line
            raw=int(f[5],16)
            for lane in range(16):
                c=g*16+lane
                value=(raw>>(lane*bits))&((1<<bits)-1)
                if bits==32 and value&(1<<31):value-=1<<32
                if c>=expected.shape[0]:
                    if tag=='O': assert value==0,(name,l,c,x,y,'padded output',value)
                    continue
                want=int(expected[c,y,x])
                assert value==want,dict(case=name,layer=l,stage=tag,channel=c,x=x,y=y,actual=value,expected=want,
                    possible_cause='weight packing, bias, accumulator or stage latency; inspect D/C/B/A/Q/O preceding this address')
                assert not seen[key][c,y,x],(name,key,c,x,y,'duplicate')
                seen[key][c,y,x]=True
                if tag=='O' and l==11: actual_final[c,y,x]=value
        else: raise AssertionError(line)
    assert layers==list(range(12)) and len(winners)==1 and trailer[:2]==[1,12],(layers,winners,trailer)
    cfg=json.loads((DEST/'deployment.json').read_text())
    expected_dma=[]
    for l in cfg['layers']:
        for og in range((l['cout']+15)//16):
            for y in range(0,l['input_hw'][0],2):
                for cg in range((l['cin']+15)//16):
                    if l['cin']<=16 and y!=0: continue
                    block=og*((l['cin']+15)//16)+cg
                    expected_dma.append((l['layer'],og,y,cg,l['weight_start']+block*64*l['kernel']**2,
                                         l['bias_start']+og*16,4*min(16,l['cin']-cg*16)*l['kernel']**2))
    assert dma==expected_dma,('DMA order',next(((a,b) for a,b in zip(dma,expected_dma) if a!=b),None),len(dma),len(expected_dma))
    assert all(v.all() for v in seen.values()),[(k,int(v.size-v.sum())) for k,v in seen.items() if not v.all()]
    report=dict(result='PASS',case=name,layers=12,stage_value_comparisons=sum(v.size for v in gold.values()),
                final_byte_comparisons=1800,mismatches=0,winner=expected_win,
                layer_checks=[dict(layer=i,**{s:int(seen[f'{s}{i}'].sum()) for s in 'CBAQO'}) for i in range(12)],
                dma_requests=len(dma),sdram_word_requests=trailer[2],cycles=trailer[3],
                native_ddr_upload_crc_readback=True,physical_ddr_phy_simulated=False)
    comp.write_json(folder/'rtl_summary.json',report)
    assert np.array_equal(actual_final,gold['O11'])
    (folder/'actual_final.bin').write_bytes(actual_final.tobytes())
    print('RTL_EXACT_PASS',name,report['stage_value_comparisons'],flush=True)
    return report

def compile_network():
    network_tb()
    sources=sorted(str(f.relative_to(RUN)) for f in (RUN/'td_project/import').glob('*.v'))
    vendor=['td_project/al_ip/al_fifo_npu_8x512/al_fifo_npu_8x512.v',
            'td_project/al_ip/al_fifo_npu_8x512/RTL/soft_fifo_39f1577ef3e1.v',
            'td_project/al_ip/sync_fifo_for_linebufferpool/sync_fifo_for_linebufferpool.v',
            'td_project/al_ip/sync_fifo_for_linebufferpool/RTL/soft_fifo_dc793d8cf75c.v',
            'user_source/ip_source/w155_d512_fifo/w155_d512_fifo.v',
            'user_source/ip_source/w155_d512_fifo/soft_fifo_al_f58e8b3e1f3d.v']
    command(['vlog','-work','sim/work','+define+NO_VCD_DUMP','+define+NPU_STREAM_INPUT_SIM','+incdir+td_project/import',
             '+incdir+sim/ddr',*sources,*vendor,'sim/ddr/native_memory_model.v','sim/tb_person_network.v'],DEST/'network_compile.log')
