"""Build a raw, stack-free RV32 demo with the project's checked instruction encoder."""
from pathlib import Path
import importlib.util
import json
BASE=Path(__file__).resolve().parent
WORK=BASE.parent.parent
spec=importlib.util.spec_from_file_location('current_boot',WORK/'vexriscv_linux_test/ddr_integration/generate_boot.py')
boot=importlib.util.module_from_spec(spec);spec.loader.exec_module(boot)
ADDRESS=0x40100000
p=boot.Program('uploaded_uart_demo')
p.li(20,0xf0001000)
p.la(6,'sentinel',ADDRESS);p.load('lw',7,6);p.li(8,0x12345678)
p.branch('bne',7,8,'bad')
p.load('lbu',7,6,8);p.li(8,0xa5);p.branch('bne',7,8,'bad')
p.li(16,0xf0001100);p.la(15,'message',ADDRESS)
p.label('print')
p.load('lbu',18,15);p.branch('beq',18,0,'passed')
p.label('tx')
p.load('lw',17,16,4);p.branch('bne',17,0,'tx')
p.store(18,16);p.addi(15,15,1);p.jump('print')
p.label('passed')
p.li(3,0xc0de0001);p.store(3,20,0x20)
p.label('heartbeat')
for offset in [8,0x2c]:
    p.load('lw',3,20,offset);p.addi(3,3,1);p.store(3,20,offset)
p.jump('heartbeat')
p.label('bad');p.li(3,0xbad30001);p.store(3,20,0x20);p.jump('bad')
p.label('message')
message=b'DOWNLOADED PROGRAM OK\r\n\0'
for i in range(0,len(message),4):p.raw(int.from_bytes(message[i:i+4].ljust(4,b'\0'),'little'),'message')
assert p.pc<=224
p.org(224);p.label('sentinel')
p.raw(0x12345678,'downloaded tail sentinel')
p.raw(0xdeadbeef,'downloaded tail bytes')
p.raw(0x000000a5,'last received byte')
p.finish()
# Final packet deliberately ends with one byte, exercising unaligned image length.
image=b''.join(p.words.get(i,(0x13,''))[0].to_bytes(4,'little') for i in range(0,236,4))[:233]
assert len(image)==233
OUT=BASE/'examples';OUT.mkdir(exist_ok=True)
(OUT/'ddr_uart_hello.bin').write_bytes(image)
(OUT/'ddr_uart_hello.lst').write_text(''.join(f'{ADDRESS+a:08x} {w:08x} {t}\n' for a,(w,t) in sorted(p.words.items())),encoding='ascii')
(OUT/'ddr_uart_hello.json').write_text(json.dumps(dict(bytes=len(image),address=ADDRESS,
    entry=ADDRESS,result=0xc0de0001,success_pc=ADDRESS+p.labels['passed'],
    labels={k:ADDRESS+v for k,v in p.labels.items()}),indent=2))
print('DEMO_BUILT bytes='+str(len(image)))
