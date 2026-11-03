"""Reproducible native-Windows RV32IMA C/assembly + real DTC build; no TD calls."""
from pathlib import Path
import hashlib,json,os,struct,subprocess
HERE=Path(__file__).resolve().parent
OUT=HERE/'build';OUT.mkdir(exist_ok=True)
ZIG=HERE/'toolchain/ziglang/zig.exe'
DTC=HERE/'toolchain/mingw64/bin/dtc.exe'
LLD=Path('D:/BaiduNetdiskDownload/Vitis_HLS/2023.2/vcxx/libexec/ld.lld.exe')
FLAGS=['-target','riscv32-freestanding','-mcpu=generic_rv32+m+a+zicsr+zifencei',
       '-mabi=ilp32','-mcmodel=medany','-msmall-data-limit=0','-Os','-g',
       '-ffreestanding','-fno-builtin','-fno-stack-protector','-fno-pic','-fno-pie',
       '-fno-unwind-tables','-fno-asynchronous-unwind-tables','-nostdlib',
       '-I','src','-I','upstream/src','-Wall','-Wextra','-Werror']
commands=[]
ENV=os.environ.copy()
ENV['ZIG_GLOBAL_CACHE_DIR']=str(HERE/'toolchain/cache/global')
ENV['ZIG_LOCAL_CACHE_DIR']=str(HERE/'toolchain/cache/local')
def run(args):
    args=list(map(str,args));commands.append(args)
    p=subprocess.run(args,cwd=HERE,env=ENV,capture_output=True,text=True,errors='replace',timeout=180)
    if p.stdout or p.stderr:print(p.stdout+p.stderr,end='',flush=True)
    if p.returncode:raise RuntimeError('Build failed: '+repr(args))
    return p.stdout
def elf(path):
    data=path.read_bytes();assert data[:6]==b'\x7fELF\x01\x01'
    hdr=struct.unpack_from('<16sHHIIIIIHHHHHH',data)
    assert hdr[2]==243 and hdr[7]==0,'ELF must be RV32, no RVC or float ABI'
    segments=[]
    for i in range(hdr[10]):
        typ,offset,va,pa,fs,ms,flags,align=struct.unpack_from('<IIIIIIII',data,hdr[5]+i*hdr[9])
        if typ==1 and fs:segments.append((pa,data[offset:offset+fs]))
    symbols={}
    sh=[struct.unpack_from('<IIIIIIIIII',data,hdr[6]+i*hdr[11]) for i in range(hdr[12])]
    for s in sh:
        if s[1]==2:
            strings=sh[s[6]];names=data[strings[4]:strings[4]+strings[5]]
            for at in range(s[4],s[4]+s[5],s[9]):
                n,value,size,info,other,index=struct.unpack_from('<IIIBBH',data,at)
                name=names[n:names.find(b'\0',n)].decode('utf-8')
                if name and index:symbols[name]=value
    base=min(a for a,b in segments);end=max(a+len(b) for a,b in segments)
    assert end-base<0x10000
    image=bytearray(end-base)
    for a,b in segments:image[a-base:a-base+len(b)]=b
    return bytes(image),dict(entry=hdr[4],address=base,bytes=len(image),symbols=symbols)
def compile_link(name,sources,script,defines=()):
    objects=[]
    for index,source in enumerate(sources):
        obj=OUT/f'{name}_{index}.o'
        run([ZIG,'cc',*FLAGS,*defines,'-c',source,'-o',obj]);objects.append(obj)
    target=OUT/(name+'.elf')
    run([LLD,'-m','elf32lriscv','--no-relax','-T',script,
         '-Map='+str(OUT/(name+'.map')),*objects,'-o',target])
    image,meta=elf(target);(OUT/(name+'.bin')).write_bytes(image)
    meta['sha256']=hashlib.sha256(image).hexdigest()
    (OUT/(name+'.json')).write_text(json.dumps(meta,indent=2))
    return image,meta

def main():
    assert ZIG.exists() and DTC.exists() and LLD.exists(),'Check the recorded portable compiler/DTC and existing Vitis LLD paths'
    print('Compiler:',subprocess.check_output([str(ZIG),'version'],text=True).strip())
    run([DTC,'-I','dts','-O','dtb','-o',OUT/'board.dtb',HERE/'board.dts'])
    run([DTC,'-I','dtb','-O','dts','-o',OUT/'board.roundtrip.dts',OUT/'board.dtb'])
    run([DTC,'-I','dts','-O','dtb','-o',OUT/'board.roundtrip.dtb',OUT/'board.roundtrip.dts'])
    assert (OUT/'board.dtb').read_bytes()==(OUT/'board.roundtrip.dtb').read_bytes()
    dtb=(OUT/'board.dtb').read_bytes();assert len(dtb)<0x1000
    (OUT/'board_dtb.S').write_text('.section .board_dtb,"a",@progbits\n.balign 8\n.incbin "build/board.dtb"\n')
    sources=['src/start.S','src/trap.S','src/read_previous.S','src/sbi.c','src/hal.c','build/board_dtb.S']
    records={}
    for name,entry,linux in [('fw_probe',0x40102000,0),('fw_jump',0x40400000,1)]:
        image,meta=compile_link(name,sources,HERE/'firmware.ld',
            ['-DNEXT_ENTRY='+hex(entry),'-DNEXT_IS_LINUX='+str(linux)])
        assert meta['address']==0x40100000 and meta['entry']==0x40100000
        records[name]={k:v for k,v in meta.items() if k!='symbols'}
        print(name,len(image),'bytes')
    for name,base in [('probe',0x40102000),('mock_image',0x40400000)]:
        ld=OUT/(name+'.ld')
        ld.write_text((HERE/'test/probe.ld').read_text().replace('PROBE_BASE',hex(base)))
        image,meta=compile_link(name,['test/probe.S','test/probe_trap.S','test/probe.c'],ld)
        assert meta['address']==base and meta['entry']==base
        records[name]={k:v for k,v in meta.items() if k!='symbols'}
        print(name,len(image),'bytes')
    fw=(OUT/'fw_probe.bin').read_bytes();payload=(OUT/'probe.bin').read_bytes()
    assert len(fw)<=0x2000 and len(payload)<0x6000
    bundle=fw.ljust(0x2000,b'\0')+payload
    (OUT/'sbi_probe.bin').write_bytes(bundle)
    records['sbi_probe']=dict(address=0x40100000,entry=0x40100000,bytes=len(bundle),
        sha256=hashlib.sha256(bundle).hexdigest(),scope='SBI + DTB + S/U acceptance payload; NOT Linux')
    image,meta=compile_link('mprv_fault',['src/start.S','src/read_previous.S',
        'test/mprv_trap.S','test/mprv_fault.c'],HERE/'firmware.ld')
    records['mprv_fault']={k:v for k,v in meta.items() if k!='symbols'}
    manifest=dict(status='BUILT',isa='RV32IMA_Zicsr_Zifencei',abi='ilp32',compiler='Zig 0.13.0 clang/LLVM',
        linker=dict(path=str(LLD),sha256=hashlib.sha256(LLD.read_bytes()).hexdigest()),
        dtc='1.8.1',records=records,commands=commands)
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
    print('SBI/DTB build complete; no RTL or TD changes')
if __name__=='__main__':main()
