"""Reuse the established RV32 musl builder and Zig native compiler; no kernel rebuild."""
from pathlib import Path
import hashlib,json,struct,subprocess,base64,re

D=Path(__file__).resolve().parent;W=D.parents[2]
ZIG=W/'firmware/vexriscv_sbi/toolchain/ziglang/zig.exe'
O=D/'build';R=W/'reports/lidar_ssh_20261025'

def main():
    from build_copy import main as build_copy
    build_copy()
    O.mkdir(exist_ok=True);R.mkdir(exist_ok=True)
    command='wget -q -O /tmp/lidar_build.sh http://10.0.2.2:18990/lidar_ssh/guest_build.sh && sh /tmp/lidar_build.sh'
    result=subprocess.run(['D:/anaconda/python.exe',str(D.parent/'guest.py'),command,'--seconds','15'],capture_output=True,text=True,errors='replace',timeout=25)
    output=result.stdout+result.stderr;(R/'compile_lidar_vm.log').write_text(output,encoding='utf8')
    match=re.search(r'\nLIDAR_ELF_BEGIN\n([A-Za-z0-9+/=\n]+)\nLIDAR_ELF_END',output.replace('\r',''))
    assert result.returncode==0 and match,'RV32 build failed; inspect compile_lidar_vm.log'
    data=base64.b64decode(match[1]);sha=hashlib.sha256(data).hexdigest()
    assert sha+'  /build/lidar_ssh_20261025/lidar_rx' in output
    (O/'lidar_rx').write_bytes(data)
    for name,target in [('lidar_rx_native.exe',[])]:
        cmd=[str(ZIG),'cc',*target,'-Os','-s','-Wall','-Wextra','-Werror',str(D/'lidar_rx.c'),'-o',str(O/name)]
        r=subprocess.run(cmd,cwd=D,capture_output=True,text=True,errors='replace',timeout=240)
        (R/('compile_'+name+'.log')).write_text(r.stdout+r.stderr,encoding='utf8')
        assert r.returncode==0,r.stdout+r.stderr
    data=(O/'lidar_rx').read_bytes()
    assert data[:6]==b'\x7fELF\x01\x01' and struct.unpack_from('<H',data,18)[0]==243
    flags=struct.unpack_from('<I',data,36)[0]
    assert flags==0,'RV32 binary must not require compressed/floating point ISA'
    phoff=struct.unpack_from('<I',data,28)[0];phsize,phnum=struct.unpack_from('<HH',data,42)
    assert not any(struct.unpack_from('<I',data,phoff+i*phsize)[0]==3 for i in range(phnum)),'dynamic interpreter'
    report=dict(status='BUILT_NOT_BOARD_TESTED',isa='RV32IMA',elf_flags=flags,static=True,
      bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),toolchain='/build/rv32-cc (existing Clang + musl)',source_sha256=hashlib.sha256((D/'lidar_rx.c').read_bytes()).hexdigest())
    (O/'manifest.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
if __name__=='__main__':main()
