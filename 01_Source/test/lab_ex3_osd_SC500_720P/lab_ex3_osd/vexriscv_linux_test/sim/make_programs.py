"""Dependency-free, checked RV32 instruction encoder for CPU-directed tests.

Every program produces a hex image and an address/word/mnemonic listing.
This is a bounded encoder, not a replacement for the Linux software toolchain.
"""
from pathlib import Path
import json

HERE = Path(__file__).resolve().parent


class Program:
    def __init__(self, name):
        self.name, self.pc = name, 0
        self.words, self.labels, self.fixups = {}, {}, []

    def emit(self, word, text):
        assert self.pc not in self.words, (self.name, self.pc)
        self.words[self.pc] = (word & 0xffffffff, text)
        self.pc += 4

    def org(self, pc):
        assert pc % 4 == 0
        self.pc = pc

    def label(self, name):
        assert name not in self.labels
        self.labels[name] = self.pc

    def i(self, opcode, funct3, rd, rs, imm, text):
        assert -2048 <= imm <= 2047
        self.emit(((imm & 4095) << 20) | (rs << 15) | (funct3 << 12) | (rd << 7) | opcode,
                  text)

    def li(self, rd, value):
        value &= 0xffffffff
        signed = value if value < 0x80000000 else value - 0x100000000
        if -2048 <= signed <= 2047:
            self.addi(rd, 0, signed)
        else:
            hi = ((value + 0x800) >> 12) & 0xfffff
            lo = (value & 0xfff)
            lo = lo if lo < 0x800 else lo - 0x1000
            self.emit((hi << 12) | (rd << 7) | 0x37, f'lui x{rd},0x{hi:x}')
            self.addi(rd, rd, lo)

    def la(self, rd, label, base=0):
        at = self.pc
        self.emit(0, f'lui x{rd},%hi({label}+0x{base:x})')
        self.emit(0, f'addi x{rd},x{rd},%lo({label}+0x{base:x})')
        self.fixups.append(('la', at, rd, label, base))

    def addi(self, rd, rs, imm):
        self.i(0x13, 0, rd, rs, imm, f'addi x{rd},x{rs},{imm}')

    def op(self, name, rd, rs1, rs2):
        f7, f3 = {'add':(0,0),'sub':(32,0),'sll':(0,1),'slt':(0,2),'sltu':(0,3),
                  'xor':(0,4),'srl':(0,5),'sra':(32,5),'or':(0,6),'and':(0,7),
                  'mul':(1,0),'div':(1,4),'divu':(1,5),'rem':(1,6)}[name]
        self.emit((f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|0x33,
                  f'{name} x{rd},x{rs1},x{rs2}')

    def load(self, name, rd, rs, off=0):
        self.i(3, {'lb':0,'lh':1,'lw':2,'lbu':4,'lhu':5}[name],rd,rs,off,
               f'{name} x{rd},{off}(x{rs})')

    def store(self, rs2, rs1, off=0, name='sw'):
        assert -2048 <= off <= 2047
        imm = off & 4095
        f3 = {'sb':0,'sh':1,'sw':2}[name]
        self.emit(((imm>>5)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&31)<<7)|0x23,
                  f'{name} x{rs2},{off}(x{rs1})')

    def csr(self, name, rd, csr, rs):
        f3 = {'csrrw':1,'csrrs':2,'csrrc':3,'csrrwi':5,'csrrsi':6,'csrrci':7}[name]
        self.emit((csr<<20)|(rs<<15)|(f3<<12)|(rd<<7)|0x73,
                  f'{name} x{rd},0x{csr:03x},{rs}')

    def readcsr(self, rd, csr):
        self.csr('csrrs',rd,csr,0)

    def writecsr(self, csr, rs):
        self.csr('csrrw',0,csr,rs)

    def branch(self, name, a, b, label):
        at = self.pc
        self.emit(0, f'{name} x{a},x{b},{label}')
        self.fixups.append(('branch',at,name,a,b,label))

    def jump(self, label, rd=0):
        at = self.pc
        self.emit(0,f'jal x{rd},{label}')
        self.fixups.append(('jump',at,rd,label))

    def check(self, rd, value):
        self.li(30,value)
        self.branch('bne',rd,30,'fail')

    def success(self):
        self.li(1,0xf0001000)
        self.li(2,0x600d0001)
        self.store(2,1)
        self.label('done')
        self.jump('done')

    def failure(self):
        self.org(0x700)
        self.label('fail')
        self.li(1,0xf0001000)
        self.li(2,0xbad00001)
        self.store(2,1)
        self.label('failed_loop')
        self.jump('failed_loop')

    def raw(self, word, name):
        self.emit(word,name)

    def atomic(self, name, rd, rs1, rs2=0):
        f5={'lr.w':2,'sc.w':3,'amoadd.w':0,'amoswap.w':1}[name]
        self.emit((f5<<27)|(rs2<<20)|(rs1<<15)|(2<<12)|(rd<<7)|0x2f,
                  f'{name} x{rd},x{rs2},(x{rs1})')

    def finish(self, extra=None):
        for f in self.fixups:
            at=f[1]
            if f[0]=='la':
                _,_,rd,label,base=f
                val=self.labels[label]+base
                hi=((val+0x800)>>12)&0xfffff
                lo=val&4095
                self.words[at]=((hi<<12)|(rd<<7)|0x37,self.words[at][1])
                self.words[at+4]=((lo<<20)|(rd<<15)|(rd<<7)|0x13,self.words[at+4][1])
            elif f[0]=='branch':
                _,_,name,a,b,label=f
                imm=self.labels[label]-at
                assert -4096<=imm<=4094 and imm%2==0
                v=imm&8191
                f3={'beq':0,'bne':1,'blt':4,'bge':5,'bltu':6,'bgeu':7}[name]
                w=((v>>12)<<31)|(((v>>5)&63)<<25)|(b<<20)|(a<<15)|(f3<<12)
                w|=(((v>>1)&15)<<8)|(((v>>11)&1)<<7)|0x63
                self.words[at]=(w,self.words[at][1])
            else:
                _,_,rd,label=f
                imm=self.labels[label]-at
                assert -1048576<=imm<=1048574 and imm%2==0
                v=imm&0x1fffff
                w=((v>>20)<<31)|(((v>>1)&1023)<<21)|(((v>>11)&1)<<20)
                w|=(((v>>12)&255)<<12)|(rd<<7)|0x6f
                self.words[at]=(w,self.words[at][1])
        for addr,val in (extra or {}).items():
            assert addr not in self.words
            self.words[addr]=(val,'data/PTE')
        image=[0x13]*16384
        for addr,(val,_) in self.words.items():
            image[addr//4]=val
        out=HERE/'programs'
        out.mkdir(exist_ok=True)
        (out/(self.name+'.hex')).write_text(''.join(f'{w:08x}\n' for w in image),encoding='ascii')
        (out/(self.name+'.lst')).write_text(''.join(
            f'{a:08x} {w:08x}  {t}\n' for a,(w,t) in sorted(self.words.items())),encoding='ascii')
        return {'name':self.name,'labels':self.labels,'first_instruction':image[0]}


def basics():
    p=Program('basic')
    p.li(3,17); p.li(4,5)
    for name,value in [('add',22),('sub',12),('xor',20),('or',21),('and',1),
                       ('sll',544),('srl',0),('slt',0),('sltu',0),
                       ('mul',85),('div',3),('divu',3),('rem',2)]:
        p.op(name,5,3,4); p.check(5,value)
    p.li(3,-64); p.li(4,2); p.op('sra',5,3,4); p.check(5,-16)
    p.li(6,0x3000); p.li(7,0x12345678); p.store(7,6); p.load('lw',8,6)
    p.check(8,0x12345678)
    p.li(7,0x80); p.store(7,6,1,'sb'); p.load('lbu',8,6,1); p.check(8,128)
    p.load('lb',8,6,1); p.check(8,-128)
    p.li(7,0x8001); p.store(7,6,2,'sh'); p.load('lhu',8,6,2); p.check(8,0x8001)
    p.load('lh',8,6,2); p.check(8,-32767)
    p.li(9,10); p.li(10,0); p.label('loop')
    p.addi(10,10,1); p.addi(9,9,-1); p.branch('bne',9,0,'loop'); p.check(10,10)
    p.jump('subroutine',11); p.label('return'); p.check(12,42)
    p.success()
    p.org(0x600); p.label('subroutine'); p.li(12,42)
    p.i(0x67,0,0,11,0,'jalr x0,0(x11)')
    p.failure()
    return p.finish()


def atomics():
    p=Program('atomic')
    p.li(6,0x3000); p.li(7,12); p.store(7,6)
    p.atomic('lr.w',8,6); p.check(8,12)
    p.li(7,21); p.atomic('sc.w',8,6,7); p.check(8,0)
    p.load('lw',8,6); p.check(8,21)
    p.li(7,5); p.atomic('amoadd.w',8,6,7); p.check(8,21)
    p.load('lw',8,6); p.check(8,26)
    p.li(7,77); p.atomic('amoswap.w',8,6,7); p.check(8,26)
    p.load('lw',8,6); p.check(8,77)
    p.success(); p.failure()
    return p.finish()


def exceptions():
    p=Program('csr_exception')
    p.la(3,'trap'); p.writecsr(0x305,3)
    p.li(3,0x1234); p.writecsr(0x340,3); p.readcsr(4,0x340); p.check(4,0x1234)
    p.csr('csrrsi',4,0x340,3); p.check(4,0x1234)
    p.csr('csrrci',4,0x340,1); p.check(4,0x1237)
    p.readcsr(4,0x340); p.check(4,0x1236)
    p.li(25,0)
    for idx,(cause,word,name) in enumerate([(11,0x73,'ecall'),(2,0xffffffff,'illegal')]):
        p.li(28,cause); p.la(27,f'resume{idx}'); p.raw(word,name); p.label(f'resume{idx}')
    p.li(28,4); p.la(27,'misaligned_done'); p.li(6,0x3001)
    p.load('lw',4,6); p.label('misaligned_done')
    p.li(28,5); p.la(27,'load_error_done'); p.li(6,0xf1000000)
    p.load('lw',4,6); p.label('load_error_done')
    p.li(28,1); p.la(27,'fetch_error_done'); p.li(6,0xf2000000)
    p.i(0x67,0,0,6,0,'jalr x0,0(x6)'); p.label('fetch_error_done')
    p.check(25,5); p.success()
    p.org(0x400); p.label('trap'); p.readcsr(29,0x342)
    p.branch('bne',29,28,'fail'); p.addi(25,25,1)
    p.writecsr(0x341,27); p.raw(0x30200073,'mret')
    p.failure()
    return p.finish()


def interrupts():
    p=Program('interrupt')
    p.la(3,'trap'); p.writecsr(0x305,3); p.li(25,0)
    # external irq0 routing is controlled by the VexRiscv custom machine mask.
    p.li(3,1); p.writecsr(0xbc0,3)
    p.li(3,0x888); p.writecsr(0x304,3)
    p.csr('csrrsi',0,0x300,8)
    p.li(1,0xf0001010); p.li(2,1); p.store(2,1)
    p.label('wait_timer'); p.li(30,1); p.branch('bne',25,30,'wait_timer')
    p.li(2,2); p.store(2,1)
    p.label('wait_software'); p.li(30,2); p.branch('bne',25,30,'wait_software')
    p.li(2,3); p.store(2,1)
    p.label('wait_external'); p.li(30,3); p.branch('bne',25,30,'wait_external')
    p.success()
    p.org(0x400); p.label('trap'); p.readcsr(29,0x342)
    p.li(30,0x80000007); p.branch('beq',29,30,'irq_ok')
    p.li(30,0x80000003); p.branch('beq',29,30,'irq_ok')
    p.li(30,0x8000000b); p.branch('bne',29,30,'fail')
    p.label('irq_ok'); p.li(31,0xf0001014); p.store(29,31)
    p.addi(25,25,1); p.raw(0x30200073,'mret'); p.failure()
    return p.finish()


def privilege():
    p=Program('privilege')
    p.la(3,'machine_trap'); p.writecsr(0x305,3)
    p.la(3,'supervisor_trap'); p.writecsr(0x105,3)
    p.li(3,1<<8); p.writecsr(0x302,3)
    p.li(3,0x800); p.writecsr(0x300,3)
    p.la(3,'supervisor'); p.writecsr(0x341,3); p.li(25,0); p.raw(0x30200073,'mret')
    p.org(0x100); p.label('supervisor')
    p.li(3,0x55aa); p.writecsr(0x140,3); p.readcsr(4,0x140); p.check(4,0x55aa)
    p.la(3,'user'); p.writecsr(0x141,3); p.writecsr(0x100,0); p.raw(0x10200073,'sret')
    p.org(0x200); p.label('user'); p.raw(0x73,'ecall U -> S')
    p.label('user_resume'); p.li(3,0x77); p.raw(0x73,'ecall U -> S (return to S)')
    p.org(0x400); p.label('supervisor_trap'); p.readcsr(29,0x142); p.check(29,8)
    p.addi(25,25,1); p.li(30,2); p.branch('beq',25,30,'leave_user')
    p.la(3,'user_resume'); p.writecsr(0x141,3); p.raw(0x10200073,'sret S -> U')
    p.label('leave_user'); p.check(3,0x77)
    p.li(3,0x100); p.writecsr(0x100,3); p.la(3,'supervisor_resume')
    p.writecsr(0x141,3); p.raw(0x10200073,'sret S -> S')
    p.org(0x500); p.label('supervisor_resume'); p.raw(0x73,'ecall S -> M')
    p.org(0x600); p.label('machine_trap'); p.readcsr(29,0x342); p.check(29,9)
    p.check(25,2); p.success(); p.failure()
    return p.finish()


def mmu():
    p=Program('mmu')
    v=0x40000000
    p.la(3,'machine_trap'); p.writecsr(0x305,3)
    p.la(3,'supervisor_trap',v); p.writecsr(0x105,3)
    p.li(3,(1<<15)|(1<<13)|(1<<8)); p.writecsr(0x302,3)
    p.li(3,0x80000008); p.writecsr(0x180,3)
    p.raw(0x12000073,'sfence.vma x0,x0')
    p.li(3,0x800); p.writecsr(0x300,3)
    p.la(3,'supervisor',v); p.writecsr(0x341,3); p.raw(0x30200073,'mret M -> S')
    p.org(0x100); p.label('supervisor')
    p.li(6,v+0x3000); p.load('lw',7,6); p.li(30,0x11223344)
    p.branch('bne',7,30,'supervisor_fail')
    p.li(7,0x12345678); p.store(7,6); p.load('lw',8,6)
    p.branch('bne',7,8,'supervisor_fail')
    # Change a populated PTE and prove sfence.vma makes the new mapping visible.
    p.li(6,v+0x900c); p.li(7,(4<<10)|0xc7); p.store(7,6)
    p.raw(0x12000073,'sfence.vma x0,x0 after PTE update')
    p.li(6,v+0x3000); p.load('lw',7,6); p.li(30,0xaabbccdd)
    p.branch('bne',7,30,'supervisor_fail')
    p.li(25,0)
    for idx,addr in enumerate([v+0x5000,v+0x1000]):
        p.li(28,13); p.li(26,addr); p.la(27,f'page_fault_resume{idx}',v)
        p.li(6,addr); p.load('lw',7,6); p.label(f'page_fault_resume{idx}')
    p.li(28,15); p.li(26,v); p.la(27,'store_fault_resume',v)
    p.li(6,v); p.store(7,6); p.label('store_fault_resume')
    p.li(30,3); p.branch('bne',25,30,'supervisor_fail')
    p.la(3,'user',v); p.writecsr(0x141,3); p.writecsr(0x100,0); p.raw(0x10200073,'sret S -> U')
    p.org(0x400); p.label('supervisor_trap'); p.readcsr(29,0x142)
    p.li(30,8); p.branch('beq',29,30,'user_ecall')
    p.branch('bne',29,28,'supervisor_fail')
    p.readcsr(29,0x143); p.branch('bne',29,26,'supervisor_fail')
    p.addi(25,25,1); p.writecsr(0x141,27)
    p.raw(0x10200073,'sret after page fault')
    p.label('user_ecall'); p.li(30,4); p.branch('bne',25,30,'supervisor_fail')
    # M trap entry bypasses translation even though satp remains active.
    p.raw(0x73,'ecall S -> M')
    p.label('supervisor_fail'); p.raw(0xffffffff,'illegal -> M')
    p.org(0x600); p.label('machine_trap'); p.readcsr(29,0x342); p.check(29,9)
    p.success(); p.failure()
    p.org(0x1000); p.label('user')
    p.li(28,13); p.li(26,v+0x3000); p.la(27,'user_fault_resume',v)
    p.li(6,v+0x3000); p.load('lw',7,6); p.label('user_fault_resume')
    p.raw(0x73,'ecall U -> S')
    # Sv32 root VPN1=256 -> L0=0x9000; U page separate from S text/data.
    data={0x8400:(9<<10)|1,0x9000:0xcb,0x9004:(1<<10)|0xdf,
          0x900c:(3<<10)|0xc7,0x9024:(9<<10)|0xc7,
          0x3000:0x11223344,0x4000:0xaabbccdd}
    return p.finish(data)


def main():
    result=[basics(),atomics(),exceptions(),interrupts(),privilege(),mmu()]
    (HERE/'programs/manifest.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('Generated:',', '.join(r['name'] for r in result))


if __name__=='__main__':
    main()
