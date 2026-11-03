"""Build the small RV32 Linux bootstrap with the existing local Zig; no VM/image rebuild."""
import hashlib,json,struct,subprocess
from pathlib import Path

D=Path(__file__).resolve().parent

def main():
    zig=D.parents[2]/'firmware/vexriscv_sbi/toolchain/ziglang/zig.exe'
    output=D/'build/copy_exact'
    args=[str(zig),'cc','-target','riscv32-freestanding','-mcpu=generic_rv32+m+a+zicsr+zifencei','-mabi=ilp32',
      '-Oz','-nostdlib','-static','-fno-stack-protector','-fno-builtin','-s',
      '-Wl,-e,_start','-Wl,--build-id=none','-Wl,-T,'+str(D/'copy_exact.ld'),
      '-Wall','-Wextra','-Werror',str(D/'copy_exact.c'),'-o',str(output)]
    subprocess.run(args,check=True)
    data=output.read_bytes()
    assert data[:6]==b'\x7fELF\x01\x01' and struct.unpack_from('<H',data,18)[0]==243
    assert struct.unpack_from('<I',data,36)[0]==0 and len(data)<2048
    state=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),
      source_sha256=hashlib.sha256((D/'copy_exact.c').read_bytes()).hexdigest(),command=args)
    (D/'build/copy_manifest.json').write_text(json.dumps(state,indent=2))
    print(json.dumps(state,indent=2))

if __name__=='__main__':main()
