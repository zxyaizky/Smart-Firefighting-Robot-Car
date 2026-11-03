"""Reproducibly build the 4 KiB hardware ROM and its CPU-loaded DDR payload.

Only the B work copy ROM and reports/cpu_ddr_integration/firmware are written.
No upstream generator is executed and no CPU configuration is changed.
"""
from pathlib import Path
import hashlib
import json
import re

WORK = Path(__file__).resolve().parents[2]
OUT = WORK / 'reports/cpu_ddr_integration/firmware'
ROM = WORK / 'td_project/import/vexriscv_b/vexriscv_b_boot_rom.v'
BACKUP = WORK / 'reports/cpu_ddr_integration/backup/td_project/import/vexriscv_b/vexriscv_b_boot_rom.v'
DDR_CODE, DDR_DATA = 0x40000000, 0x40001000
DDR_FAIL, DDR_PASS = 0xBAD20001, 0xD00D0001
READY_TIMEOUT_CYCLES = 500000000
ROM_BYTES = 4096
UART_BASE = 0xf0001100
UART_INIT, UART_PASS, UART_POLL, UART_FAIL = 0x800, 0x830, 0x860, 0x8c0
DOWNLOAD_MIN, DOWNLOAD_LIMIT = 0x40010000, 0x41fff000
DOWNLOAD_MAGIC = 0x31445256  # wire bytes VRD1
CAPACITY_BYTES = 32 * 1024 * 1024
CAPACITY_SEED = 0xA5A55A5A

# Loading definitions with __name__ != '__main__' never invokes the old program
# generation entrypoint. Override finish below so its file writes cannot run.
namespace = {'__name__': 'rv32_encoders_only', '__file__': str(WORK / 'vexriscv_linux_test/sim/make_programs.py')}
exec(compile(Path(namespace['__file__']).read_text(), namespace['__file__'], 'exec'), namespace)


class Program(namespace['Program']):
    def finish(self, extra=None):
        for f in self.fixups:
            at = f[1]
            if f[0] == 'la':
                _, _, rd, label, base = f
                value = self.labels[label] + base
                self.words[at] = ((((value + 0x800) >> 12 & 0xfffff) << 12) | (rd << 7) | 0x37, self.words[at][1])
                self.words[at + 4] = (((value & 4095) << 20) | (rd << 15) | (rd << 7) | 0x13, self.words[at + 4][1])
            elif f[0] == 'branch':
                _, _, name, rs1, rs2, label = f
                delta = self.labels[label] - at
                assert -4096 <= delta <= 4094 and delta % 2 == 0
                v = delta & 8191
                funct3 = {'beq': 0, 'bne': 1, 'blt': 4, 'bge': 5, 'bltu': 6, 'bgeu': 7}[name]
                word = ((v >> 12) << 31) | (((v >> 5) & 63) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12)
                word |= (((v >> 1) & 15) << 8) | (((v >> 11) & 1) << 7) | 0x63
                self.words[at] = (word, self.words[at][1])
            else:
                _, _, rd, label = f
                delta = self.labels[label] - at
                assert -1048576 <= delta <= 1048574 and delta % 2 == 0
                v = delta & 0x1fffff
                word = ((v >> 20) << 31) | (((v >> 1) & 1023) << 21) | (((v >> 11) & 1) << 20)
                word |= (((v >> 12) & 255) << 12) | (rd << 7) | 0x6f
                self.words[at] = (word, self.words[at][1])
        return self.words

    def dcheck(self, rd, value, fail='ddr_fail'):
        self.li(30, value)
        self.branch('bne', rd, 30, fail)

    def andi(self, rd, rs, value):
        self.i(0x13, 7, rd, rs, value, f'andi x{rd},x{rs},{value}')

    def console_call(self, address):
        self.li(13, address)
        self.i(0x67, 0, 12, 13, 0, 'jalr x12,0(x13): CPU UART console')

    def sync_code(self):
        # Ordered D-bus MMIO read drains previous acknowledged DDR stores.
        self.load('lw', 3, 20, 0x30)
        self.branch('bne', 3, 0, 'payload_fail' if self.name == 'ddr_payload' else 'ddr_fail')
        self.raw(0x0ff0000f, 'fence iorw,iorw (ordering supplied by serial interconnect)')
        self.raw(0x0000100f, 'fence.i')
        for _ in range(3):
            self.raw(0x00000013, 'nop after fence.i (upstream sequence)')


def make_payload():
    q = Program('ddr_payload')
    q.label('entry')
    q.li(20, 0xf0001000)
    q.li(6, DDR_DATA)
    q.li(3, 7); q.li(4, 9); q.op('mul', 5, 3, 4)
    q.dcheck(5, 63, 'payload_fail')
    q.store(5, 6, 0x200); q.load('lw', 7, 6, 0x200)
    q.branch('bne', 5, 7, 'payload_fail')
    q.li(9, 4)
    q.label('arithmetic_loop')
    q.addi(7, 7, 1); q.addi(9, 9, -1)
    q.branch('bne', 9, 0, 'arithmetic_loop')
    q.dcheck(7, 67, 'payload_fail')
    q.jump('patch_target', 12)
    q.dcheck(14, 1, 'payload_fail')
    q.la(10, 'patch_target', DDR_CODE)
    q.li(7, 0x00200713)  # addi x14,x0,2 replaces addi x14,x0,1.
    q.store(7, 10)
    q.sync_code()
    q.jump('patch_target', 12)
    q.dcheck(14, 2, 'payload_fail')
    q.load('lw', 3, 20, 0x24); q.andi(3, 3, 8)
    q.branch('bne', 3, 0, 'payload_fail')
    q.li(3, DDR_PASS)
    q.label('pass_store')
    q.store(3, 20, 0x28)
    q.console_call(UART_PASS)
    q.li(11, 0)
    q.label('heartbeat_loop')
    q.load('lw', 3, 20, 8); q.addi(3, 3, 1); q.store(3, 20, 8)
    q.addi(11, 11, 1); q.store(11, 20, 0x2c)
    q.store(11, 6, 0x204); q.load('lw', 8, 6, 0x204)
    q.branch('bne', 11, 8, 'payload_fail')
    q.load('lw', 8, 6)
    q.dcheck(8, 0x12345678, 'payload_fail')
    q.load('lw', 3, 20, 0x30)
    q.branch('bne', 3, 0, 'payload_fail')
    q.console_call(UART_POLL)
    q.jump('heartbeat_loop')
    q.label('patch_target')
    q.addi(14, 0, 1)
    q.i(0x67, 0, 0, 12, 0, 'jalr x0,0(x12)')
    q.label('payload_fail')
    q.li(6, 0x740)
    q.i(0x67, 0, 0, 6, 0, 'jalr x0,0(x6): ROM DDR failure handler')
    q.finish()
    assert q.pc <= 0x600 - 0x450, hex(q.pc)
    return q


def emit_serial_loader(p):
    """ROM-resident stop/wait loader; never executes from the download region.

    x22/23/24 save the DDR selftest's x6/11/12. x20 stays MMIO base.
    Header and one 64-byte packet reuse the existing local 64-byte RAM.
    No stack or extra RTL is needed until the downloaded entry takes control.
    """
    p.org(0xb00); p.label('serial_loader')
    p.addi(22, 6, 0); p.addi(23, 11, 0); p.addi(24, 12, 0)
    p.la(15, 'uart_loader_text'); p.jump('uart_puts', 14)
    p.la(3, 'loader_fault'); p.writecsr(0x305, 3)
    p.li(19, 0xedb88320); p.li(21, 100000000)
    p.li(18, 3); p.store(18, 16, 0x18)  # W1C old framing/overflow.
    p.li(10, 0x1000); p.li(8, 24)
    p.label('loader_header_receive')
    p.jump('loader_rx', 1); p.store(18, 10, 0, 'sb')
    p.addi(10, 10, 1); p.addi(8, 8, -1)
    p.branch('bne', 8, 0, 'loader_header_receive')
    p.li(10, 0x1000); p.li(8, 20); p.jump('loader_crc', 1)
    p.load('lw', 25, 10); p.branch('bne', 11, 25, 'loader_error_header')
    p.li(10, 0x1000); p.load('lw', 3, 10); p.li(17, DOWNLOAD_MAGIC)
    p.branch('bne', 3, 17, 'loader_error_header')
    for rd, off in [(2,4),(4,8),(5,12),(6,16)]:p.load('lw', rd, 10, off)
    p.li(17, DOWNLOAD_MIN); p.branch('bltu', 2, 17, 'loader_error_range')
    p.li(17, DOWNLOAD_LIMIT); p.branch('bgeu', 2, 17, 'loader_error_range')
    p.li(3, 4); p.branch('bltu', 4, 3, 'loader_error_range')
    p.op('sub', 17, 17, 2); p.branch('bltu', 17, 4, 'loader_error_range')
    p.op('or', 3, 2, 5); p.andi(3, 3, 3); p.branch('bne', 3, 0, 'loader_error_range')
    p.branch('bltu', 5, 2, 'loader_error_range')
    p.op('add', 17, 2, 4); p.addi(17, 17, -4)
    p.branch('bltu', 17, 5, 'loader_error_range')
    p.addi(7, 2, 0); p.addi(27, 4, 0)
    p.li(18, ord('K')); p.jump('loader_tx', 1)
    p.label('loader_packet')
    p.li(9, 64); p.branch('bgeu', 27, 9, 'loader_packet_size')
    p.addi(9, 27, 0)
    p.label('loader_packet_size')
    p.li(10, 0x1000); p.addi(8, 9, 0)
    p.label('loader_packet_receive')
    p.jump('loader_rx', 1); p.store(18, 10, 0, 'sb')
    p.addi(10, 10, 1); p.addi(8, 8, -1)
    p.branch('bne', 8, 0, 'loader_packet_receive')
    p.li(10, 0x1000); p.addi(8, 9, 0); p.jump('loader_crc', 1)
    p.addi(26, 11, 0); p.li(25, 0); p.li(13, 0); p.li(14, 4)
    p.label('loader_packet_crc_receive')
    p.jump('loader_rx', 1); p.op('sll', 18, 18, 13); p.op('or', 25, 25, 18)
    p.addi(13, 13, 8); p.addi(14, 14, -1)
    p.branch('bne', 14, 0, 'loader_packet_crc_receive')
    p.branch('bne', 26, 25, 'loader_error_crc')
    p.li(10, 0x1000); p.addi(8, 9, 0)
    p.label('loader_commit')
    p.load('lbu', 18, 10); p.store(18, 7, 0, 'sb')
    p.addi(10, 10, 1); p.addi(7, 7, 1); p.addi(8, 8, -1)
    p.branch('bne', 8, 0, 'loader_commit')
    p.load('lw', 17, 20, 0x30); p.branch('bne', 17, 0, 'loader_error_ddr')
    p.op('sub', 27, 27, 9)
    p.li(18, ord('K')); p.jump('loader_tx', 1)
    p.branch('bne', 27, 0, 'loader_packet')
    # Populate every Dcache index with known reserved scratch data. This evicts
    # received bytes before CRC readback, including the most recently written line.
    p.li(10, DDR_CODE+0x8000); p.li(8, 32)
    p.label('loader_evict')
    p.store(0, 10); p.load('lw', 17, 10)
    p.addi(10, 10, 32); p.addi(8, 8, -1)
    p.branch('bne', 8, 0, 'loader_evict')
    p.addi(10, 2, 0); p.addi(8, 4, 0); p.jump('loader_crc', 1)
    p.branch('bne', 11, 6, 'loader_error_crc')
    p.load('lw', 17, 20, 0x30); p.branch('bne', 17, 0, 'loader_error_ddr')
    p.li(18, ord('V')); p.jump('loader_tx', 1)
    p.label('loader_tx_drain')
    p.load('lw', 17, 16, 4); p.branch('bne', 17, 0, 'loader_tx_drain')
    p.raw(0x0ff0000f, 'fence: previous serial MMIO read already drained DDR stores')
    p.raw(0x0000100f, 'fence.i before downloaded instructions')
    for _ in range(3):p.raw(0x13,'nop after fence.i')
    p.writecsr(0x304, 0); p.writecsr(0x180, 0); p.raw(0x12000073, 'sfence.vma')
    p.la(3, 'loader_run_fault'); p.writecsr(0x305, 3)
    p.addi(7, 5, 0); p.li(2, 0x41fffff0)
    p.li(10, 0); p.li(11, 0); p.li(1, 0)
    p.label('loader_jump')
    p.i(0x67, 0, 0, 7, 0, 'jalr x0,0(x7): execute verified uploaded entry in M mode')
    for label,code in [('header','H'),('range','R'),('crc','C'),('timeout','T'),('uart','U'),('ddr','E')]:
        p.label('loader_error_'+label); p.li(18, ord(code)); p.jump('loader_abort')
    p.label('loader_fault'); p.readcsr(3, 0x342); p.store(3, 20, 0xc)
    p.jump('loader_error_ddr')
    p.label('loader_abort')
    p.li(17, 0xbad30000); p.op('or', 17, 17, 18); p.store(17, 20, 0x20)
    p.jump('loader_tx', 1)
    p.la(3, 'ddr_trap'); p.writecsr(0x305, 3)
    p.addi(6, 22, 0); p.addi(11, 23, 0); p.addi(12, 24, 0)
    p.jump('uart_poll_return')
    # Uploaded programs have no callable ROM return ABI. Unexpected traps stop
    # safely in ROM and record mcause; they never manufacture a download PASS.
    p.label('loader_run_fault')
    p.li(20, 0xf0001000); p.readcsr(3, 0x342); p.store(3, 20, 0xc)
    p.li(3, 0xbad30045); p.store(3, 20, 0x20)
    p.li(16, UART_BASE); p.li(18, ord('E')); p.jump('loader_tx', 1)
    p.label('loader_run_halt'); p.jump('loader_run_halt')
    p.label('loader_rx')
    p.load('lw', 29, 20, 4)
    p.label('loader_rx_wait')
    p.load('lw', 17, 16, 0x18); p.branch('bne', 17, 0, 'loader_error_uart')
    p.load('lw', 17, 16, 8); p.branch('beq', 17, 0, 'loader_rx_ready')
    p.load('lw', 15, 20, 4); p.op('sub', 15, 15, 29)
    p.branch('bgeu', 15, 21, 'loader_error_timeout'); p.jump('loader_rx_wait')
    p.label('loader_rx_ready')
    p.load('lw', 18, 16); p.li(17, 2); p.store(17, 16, 0x10)
    p.i(0x67, 0, 0, 1, 0, 'return RX byte x18')
    p.label('loader_tx')
    p.load('lw', 17, 16, 4); p.branch('bne', 17, 0, 'loader_tx')
    p.store(18, 16); p.i(0x67, 0, 0, 1, 0, 'return after UART accepted byte')
    p.label('loader_crc')
    p.li(11, -1)
    p.label('loader_crc_byte')
    p.load('lbu', 18, 10); p.op('xor', 11, 11, 18); p.li(13, 8)
    p.label('loader_crc_bit')
    p.andi(14, 11, 1); p.i(0x13, 5, 11, 11, 1, 'srli CRC,CRC,1')
    p.branch('beq', 14, 0, 'loader_crc_next_bit'); p.op('xor', 11, 11, 19)
    p.label('loader_crc_next_bit')
    p.addi(13, 13, -1); p.branch('bne', 13, 0, 'loader_crc_bit')
    p.addi(10, 10, 1); p.addi(8, 8, -1)
    p.branch('bne', 8, 0, 'loader_crc_byte')
    p.i(0x13, 4, 11, 11, -1, 'xori CRC,CRC,-1')
    p.i(0x67, 0, 0, 1, 0, 'return CRC32/ISO-HDLC x11')
    assert p.pc <= ROM_BYTES, hex(p.pc)


def make_rom(payload):
    p = Program('board_boot_ddr')
    # Keep the established CSR, RV32M, LR/SC, AMO and Sv32 test at the same PCs.
    p.la(3, 'trap'); p.writecsr(0x305, 3)
    p.li(25, 0); p.li(3, 0x1234); p.writecsr(0x340, 3)
    p.readcsr(4, 0x340); p.check(4, 0x1234)
    p.li(3, 17); p.li(4, 5)
    for name, value in [('add', 22), ('xor', 20), ('mul', 85), ('div', 3)]:
        p.op(name, 5, 3, 4); p.check(5, value)
    p.li(6, 0x1000); p.li(7, 0x12345678); p.store(7, 6)
    p.load('lw', 8, 6); p.check(8, 0x12345678)
    p.li(7, 0x80); p.store(7, 6, 1, 'sb'); p.load('lb', 8, 6, 1); p.check(8, -128)
    p.li(7, 12); p.store(7, 6); p.atomic('lr.w', 8, 6); p.check(8, 12)
    p.li(7, 21); p.atomic('sc.w', 8, 6, 7); p.check(8, 0)
    p.li(7, 5); p.atomic('amoadd.w', 8, 6, 7); p.check(8, 21)
    p.load('lw', 8, 6); p.check(8, 26)
    p.li(20, 0xf0001000)
    p.li(3, 1); p.writecsr(0xbc0, 3)
    p.li(3, 0x888); p.writecsr(0x304, 3); p.csr('csrrsi', 0, 0x300, 8)
    p.li(3, 1); p.store(3, 20, 0x10); p.store(3, 20, 0x18); p.store(3, 20, 0x14)
    p.writecsr(0x304, 0)
    p.li(6, 0x2400); p.li(7, 0xc01); p.store(7, 6)
    p.li(6, 0x3000); p.li(7, 0xcb); p.store(7, 6)
    p.li(7, 0x4c7); p.store(7, 6, 4)
    p.li(3, 0x80000002); p.writecsr(0x180, 3); p.raw(0x12000073, 'sfence.vma')
    p.la(3, 'supervisor', 0x40000000); p.writecsr(0x341, 3)
    p.li(3, 0x800); p.writecsr(0x300, 3); p.raw(0x30200073, 'mret M -> S')
    p.label('after_supervisor')
    p.li(20, 0xf0001000); p.li(3, 0x600d0001); p.store(3, 20)
    p.li(11, 0); p.li(3, 0x888); p.writecsr(0x304, 3); p.csr('csrrsi', 0, 0x300, 8)
    p.li(3, 1); p.store(3, 20, 0x14)
    p.label('heartbeat_loop')
    p.load('lw', 10, 20, 4); p.addi(11, 11, 1); p.op('xor', 7, 10, 11)
    p.li(6, 0x1000); p.store(7, 6, 8); p.load('lw', 8, 6, 8)
    p.branch('bne', 7, 8, 'fail'); p.store(11, 20, 8); p.store(8, 20, 0x20)
    assert p.pc == 0x1c0
    p.jump('ddr_entry')  # Only changed word in the established selftest sections.

    p.label('ddr_entry')
    p.load('lw', 3, 20, 0x24); p.andi(4, 3, 2)
    p.branch('beq', 4, 0, 'heartbeat_loop')
    p.load('lw', 4, 20, 0x28)
    p.branch('bne', 4, 0, 'heartbeat_loop')
    p.andi(4, 3, 1); p.branch('bne', 4, 0, 'ddr_begin')
    p.load('lw', 4, 20, 4); p.li(5, READY_TIMEOUT_CYCLES)
    p.branch('bltu', 4, 5, 'heartbeat_loop')
    p.jump('ddr_fail')
    p.label('ddr_begin')
    p.writecsr(0x304, 0); p.csr('csrrci', 0, 0x300, 8)
    p.la(3, 'ddr_trap'); p.writecsr(0x305, 3)
    p.li(3, 1); p.store(3, 20, 0x28)  # Explicit RUNNING status.
    p.console_call(UART_INIT)
    # ROM is executing with interrupts disabled; DDR code/data are loaded later.
    p.jump('capacity_entry', 12)
    p.li(6, DDR_DATA); p.la(10, 'patterns'); p.li(9, 5)
    p.label('pattern_loop')
    p.load('lw', 7, 10); p.store(7, 6); p.load('lw', 8, 6)
    p.branch('bne', 7, 8, 'ddr_fail')
    p.addi(10, 10, 4); p.addi(6, 6, 4); p.addi(9, 9, -1)
    p.branch('bne', 9, 0, 'pattern_loop')
    p.li(6, DDR_DATA + 0x40); p.store(0, 6)
    p.li(9, 4); p.li(7, 0x80)
    p.label('byte_loop')
    p.store(7, 6, 0, 'sb'); p.load('lbu', 8, 6)
    p.branch('bne', 7, 8, 'ddr_fail')
    p.load('lb', 8, 6); p.addi(10, 7, -256)
    p.branch('bne', 10, 8, 'ddr_fail')
    p.addi(6, 6, 1); p.addi(7, 7, 1); p.addi(9, 9, -1)
    p.branch('bne', 9, 0, 'byte_loop')
    p.load('lw', 8, 6, -4); p.dcheck(8, 0x83828180)
    p.li(6, DDR_DATA + 0x60); p.li(7, 0x8001)
    p.store(7, 6, 0, 'sh'); p.load('lhu', 8, 6); p.dcheck(8, 0x8001)
    p.load('lh', 8, 6); p.dcheck(8, -32767)
    p.li(7, 0x7ffe); p.store(7, 6, 2, 'sh')
    p.load('lhu', 8, 6, 2); p.dcheck(8, 0x7ffe)
    p.load('lw', 8, 6); p.dcheck(8, 0x7ffe8001)
    p.li(6, DDR_DATA + 0x7c); p.li(7, 0x11223344); p.store(7, 6)
    p.li(7, 0x55667788); p.store(7, 6, 4)
    p.load('lw', 8, 6); p.dcheck(8, 0x11223344)
    p.load('lw', 8, 6, 4); p.dcheck(8, 0x55667788)
    p.li(6, DDR_DATA + 0x100); p.li(7, 12); p.store(7, 6)
    p.atomic('lr.w', 8, 6); p.dcheck(8, 12)
    p.li(7, 21); p.atomic('sc.w', 8, 6, 7); p.dcheck(8, 0)
    p.atomic('sc.w', 8, 6, 7); p.dcheck(8, 1)
    p.li(7, 5); p.atomic('amoadd.w', 8, 6, 7); p.dcheck(8, 21)
    p.load('lw', 8, 6); p.dcheck(8, 26)
    p.li(7, 77); p.atomic('amoswap.w', 8, 6, 7); p.dcheck(8, 26)
    p.load('lw', 8, 6); p.dcheck(8, 77)
    p.jump('ddr_loader')
    assert p.pc <= 0x400, hex(p.pc)

    p.org(0x400); p.label('supervisor')
    p.li(3, 0x55aa); p.writecsr(0x140, 3); p.readcsr(4, 0x140)
    p.li(30, 0x55aa); p.branch('bne', 4, 30, 'supervisor_fail')
    p.li(6, 0x40001000); p.load('lw', 8, 6); p.li(30, 26)
    p.branch('bne', 8, 30, 'supervisor_fail')
    p.li(7, 0xabcdef01); p.store(7, 6); p.load('lw', 8, 6)
    p.branch('bne', 7, 8, 'supervisor_fail'); p.raw(0x73, 'ecall S -> M')
    p.label('supervisor_fail'); p.raw(0xffffffff, 'illegal S -> M (FAIL)')
    p.org(0x450); p.label('payload')
    for at, (word, text) in sorted(payload.words.items()):
        assert p.pc == at + 0x450
        p.raw(word, f'DDR[{DDR_CODE + at:08x}] {text}')
    assert p.pc <= 0x600
    p.org(0xa00); p.label('capacity_walk')
    # All word address lines, every MiB, and the final word; write ALL before read.
    p.li(18, DDR_CODE); p.li(19, 4); p.li(21, CAPACITY_BYTES)
    p.label('capacity_address_line')
    p.op('add', 6, 18, 19); p.jump('capacity_word', 14)
    p.i(0x13, 1, 19, 19, 1, 'slli x19,x19,1')
    p.branch('bltu', 19, 21, 'capacity_address_line')
    p.li(6, DDR_CODE); p.li(19, 0x100000); p.li(21, DDR_CODE + CAPACITY_BYTES)
    p.label('capacity_each_mib')
    p.jump('capacity_word', 14); p.op('add', 6, 6, 19)
    p.branch('bltu', 6, 21, 'capacity_each_mib')
    p.li(6, DDR_CODE + CAPACITY_BYTES - 4); p.jump('capacity_word', 14)
    p.i(0x67, 0, 0, 13, 0, 'jalr x0,0(x13): capacity walk return')
    p.label('capacity_word')
    p.op('xor', 7, 6, 15); p.branch('bne', 17, 0, 'capacity_read')
    p.store(7, 6); p.jump('capacity_word_return')
    p.label('capacity_read')
    p.load('lw', 8, 6); p.branch('bne', 8, 7, 'ddr_fail')
    p.label('capacity_word_return')
    p.i(0x67, 0, 0, 14, 0, 'jalr x0,0(x14): capacity word return')
    assert p.pc <= 0xb00, hex(p.pc)
    p.org(0x600); p.label('trap')
    p.readcsr(29, 0x342); p.li(28, 0xf0001000); p.store(29, 28, 0xc)
    p.branch('blt', 29, 0, 'irq_handler')
    p.li(28, 9); p.branch('bne', 29, 28, 'fail')
    p.writecsr(0x180, 0); p.raw(0x12000073, 'sfence.vma after M trap')
    p.la(28, 'after_supervisor'); p.writecsr(0x341, 28)
    p.li(28, 0x1800); p.writecsr(0x300, 28); p.raw(0x30200073, 'mret to physical M continuation')
    p.label('irq_handler'); p.addi(25, 25, 1); p.li(28, 0xf0001000)
    p.store(0, 28, 0x10); p.store(0, 28, 0x18)
    p.li(29, 1); p.store(29, 28, 0x14); p.raw(0x30200073, 'mret from interrupt')
    p.org(0x660); p.label('ddr_loader')
    # Force the earlier atomic cache line to be replaced, then check DDR data.
    p.li(6, DDR_DATA + 0x500); p.store(0, 6); p.load('lw', 8, 6)
    p.li(6, DDR_DATA + 0x100); p.load('lw', 8, 6); p.dcheck(8, 77)
    p.li(6, DDR_CODE); p.la(10, 'payload'); p.li(9, payload.pc // 4)
    p.label('copy_payload')
    p.load('lw', 7, 10); p.store(7, 6)
    p.addi(10, 10, 4); p.addi(6, 6, 4); p.addi(9, 9, -1)
    p.branch('bne', 9, 0, 'copy_payload')
    p.sync_code()
    p.li(6, DDR_CODE)
    p.label('jump_ddr')
    p.i(0x67, 0, 0, 6, 0, 'jalr x0,0(x6): enter CPU-loaded DDR program')
    assert p.pc <= 0x700, hex(p.pc)
    p.failure()
    p.org(0x720); p.label('patterns')
    for word in [0x12345678, 0, 0xffffffff, 0xaaaaaaaa, 0x55555555]:
        p.raw(word, 'DDR test pattern')
    p.org(0x740); p.label('ddr_fail')
    p.li(20, 0xf0001000); p.li(3, DDR_FAIL); p.store(3, 20, 0x28)
    p.console_call(UART_FAIL)
    p.jump('heartbeat_loop')
    p.org(0x780); p.label('ddr_trap')
    p.readcsr(29, 0x342); p.li(28, 0xf0001000); p.store(29, 28, 0xc)
    p.jump('ddr_fail')
    p.label('capacity_entry')
    p.li(15, CAPACITY_SEED); p.li(16, 2)
    p.label('capacity_phase')
    p.li(17, 0); p.jump('capacity_walk', 13)
    p.load('lw', 3, 20, 0x30); p.branch('bne', 3, 0, 'ddr_fail')
    # Replace all 32 lines of the current direct-mapped 1 KiB write-through D$.
    p.li(6, DDR_CODE + 0x8000); p.li(9, DDR_CODE + 0x8400)
    p.label('capacity_evict')
    p.load('lw', 3, 6); p.addi(6, 6, 32)
    p.branch('bltu', 6, 9, 'capacity_evict')
    p.li(17, 1); p.jump('capacity_walk', 13)
    p.i(0x13, 4, 15, 15, -1, 'xori x15,x15,-1: complement address pattern')
    p.addi(16, 16, -1); p.branch('bne', 16, 0, 'capacity_phase')
    p.label('capacity_done')
    p.i(0x67, 0, 0, 12, 0, 'jalr x0,0(x12): capacity success, resume DDR tests')
    assert p.pc <= UART_INIT
    p.org(UART_INIT); p.label('uart_init')
    p.la(15, 'uart_boot_text'); p.jump('uart_puts', 14)
    p.i(0x67, 0, 0, 12, 0, 'jalr x0,0(x12): UART init return')
    p.org(UART_PASS); p.label('uart_pass')
    p.la(15, 'uart_pass_text'); p.jump('uart_puts', 14)
    p.i(0x67, 0, 0, 12, 0, 'jalr x0,0(x12): UART PASS return')
    p.org(UART_POLL); p.label('uart_poll')
    p.li(16, UART_BASE); p.load('lw', 17, 16, 8)
    p.branch('bne', 17, 0, 'uart_poll_return')
    p.load('lw', 17, 16); p.li(18, 2); p.store(18, 16, 0x10)
    p.li(18, ord('l')); p.branch('beq', 17, 18, 'serial_loader')
    p.li(18, ord('s')); p.branch('beq', 17, 18, 'uart_status')
    p.li(18, ord('h')); p.branch('beq', 17, 18, 'uart_help')
    p.li(18, ord('?')); p.branch('beq', 17, 18, 'uart_help')
    p.label('uart_poll_return')
    p.i(0x67, 0, 0, 12, 0, 'jalr x0,0(x12): UART polling return')
    p.label('uart_status'); p.la(15, 'uart_pass_text'); p.jump('uart_puts', 14)
    p.jump('uart_poll_return')
    p.label('uart_help'); p.la(15, 'uart_help_text'); p.jump('uart_puts', 14)
    p.jump('uart_poll_return')
    assert p.pc <= UART_FAIL, hex(p.pc)
    p.org(UART_FAIL); p.label('uart_fail')
    p.la(15, 'uart_fail_text'); p.jump('uart_puts', 14)
    p.i(0x67, 0, 0, 12, 0, 'jalr x0,0(x12): UART failure return')
    p.org(0x8e0); p.label('uart_puts')
    p.li(16, UART_BASE); p.load('lw', 17, 16, 0x1c); p.li(18, 0x55415254)
    p.branch('bne', 17, 18, 'uart_puts_return')
    p.label('uart_puts_loop'); p.load('lbu', 18, 15)
    p.branch('beq', 18, 0, 'uart_puts_return')
    p.label('uart_puts_wait'); p.load('lw', 17, 16, 4)
    p.branch('bne', 17, 0, 'uart_puts_wait')
    p.store(18, 16); p.addi(15, 15, 1); p.jump('uart_puts_loop')
    p.label('uart_puts_return')
    p.i(0x67, 0, 0, 14, 0, 'jalr x0,0(x14): UART string return')
    assert p.pc <= 0x940
    p.org(0x940)
    for label, text in [('uart_boot_text', 'VexRiscv BOOT\r\n'),
                        ('uart_pass_text', 'DDR32 PASS\r\n> '),
                        ('uart_fail_text', 'DDR32 FAIL\r\n'),
                        ('uart_help_text', 'h:help s:status l:load\r\n> '),
                        ('uart_loader_text', 'VRDL READY\r\n')]:
        p.label(label)
        data = text.encode('ascii') + b'\0'
        data += b'\0' * (-len(data) % 4)
        for i in range(0, len(data), 4):
            p.raw(int.from_bytes(data[i:i+4], 'little'), 'UART string')
    assert p.pc <= 0xa00
    emit_serial_loader(p)
    p.finish()
    assert max(p.words) < ROM_BYTES
    return p


def main():
    payload = make_payload()
    p = make_rom(payload)
    old_words = {int(i) * 4: int(word, 16) for i, word in re.findall(r"rom_words\[(\d+)\] = 32'h([0-9a-f]+)", BACKUP.read_text())}
    protected = [a for a, w in old_words.items() if w != 0x13]
    changes = [a for a in protected if p.words.get(a, (0x13, ''))[0] != old_words[a]]
    assert changes == [0x1c0], [hex(a) for a in changes]
    image = [p.words.get(i * 4, (0x13, 'nop padding'))[0] for i in range(ROM_BYTES // 4)]
    text = '''// -----------------------------------------------------------------------------
// File   : vexriscv_b_boot_rom.v
// Author : Codex
// Date   : 2026-10-17
// -----------------------------------------------------------------------------
// Description:
//   4 KiB synchronous constant ERAM boot ROM. Original CPU selftest plus
//   optional 32 MiB address-capacity test, payload copy and DDR execution.
//   Generated by vexriscv_linux_test/ddr_integration/generate_boot.py.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-19  Codex  v3.4  CRC-checked UART loader executes verified DDR binaries.
//   2026-10-19  Codex  v3.3  4 KiB ROM with polling UART startup and h/s console.
//   2026-10-17  Codex  v3.0  Preserve original selftest and add DDR software boot.
//   2026-10-17  Codex  v3.1  XOR storage keeps ERAM register init zero and visible NOP.
//   2026-10-19  Codex  v3.2  Check 32 MiB address lines/MiB/end before DDR PASS.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module vexriscv_b_boot_rom
(
    input  wire        clk,
    input  wire        enable_i,
    input  wire [9:0]  word_address_i,
    output wire [31:0] instruction_o
);
    // TD cannot infer ERAM with a nonzero read-register initial value.
    // Encode words with NOP, then decode after the zero-initialized register.
    (* rom_style = "bram" *) reg [31:0] rom_words [0:1023];
    reg [31:0] instruction_reg = 32'd0;

    initial begin
'''
    text += ''.join(f"        rom_words[{i}] = 32'h{word ^ 0x13:08x};\n" for i, word in enumerate(image))
    text += '''    end

    assign instruction_o = instruction_reg ^ 32'h00000013;
    always @(posedge clk) begin
        if (enable_i) instruction_reg <= rom_words[word_address_i];
    end
endmodule
`resetall
'''
    OUT.mkdir(parents=True, exist_ok=True)
    ROM.write_text(text, encoding='ascii')
    listing = lambda prog, base=0: ''.join(f'{base + a:08x} {word:08x}  {mnemonic}\n' for a, (word, mnemonic) in sorted(prog.words.items()))
    (OUT / 'boot_program.lst').write_text(listing(p), encoding='ascii')
    (OUT / 'ddr_payload.lst').write_text(listing(payload, DDR_CODE), encoding='ascii')
    (OUT / 'boot_program.hex').write_text(''.join(f'{word:08x}\n' for word in image), encoding='ascii')
    meta = {'rom_window_bytes': ROM_BYTES, 'implemented_words_including_payload': len(p.words),
            'serial_loader': {'load_min': DOWNLOAD_MIN, 'load_limit_exclusive': DOWNLOAD_LIMIT,
                'header_magic': DOWNLOAD_MAGIC, 'header_bytes': 24, 'packet_bytes': 64,
                'crc': 'CRC32/ISO-HDLC, zlib.crc32', 'byte_timeout_cycles': 100000000,
                'stack_top': 0x41fffff0, 'mode': 'M, bare, a0=0 a1=0, no return ABI'},
            'payload_bytes': payload.pc, 'uart_base': UART_BASE, 'uart_baud': 115200, 'reset_vector': 0, 'ddr_code': DDR_CODE, 'ddr_data': DDR_DATA,
            'rom_labels': p.labels, 'payload_labels': {name: DDR_CODE + addr for name, addr in payload.labels.items()},
            'boot_success_pc': 0x178, 'ddr_pass_store_pc': DDR_CODE + payload.labels['pass_store'],
            'ddr_success': DDR_PASS, 'ddr_failure': DDR_FAIL,
            'ready_timeout_cycles_50mhz': READY_TIMEOUT_CYCLES,
            'original_instruction_changes': [hex(a) for a in changes],
            'rom_storage_xor_mask': 0x13,
            'rom_sha256': hashlib.sha256(ROM.read_bytes()).hexdigest(),
            'memory_model': 'write-through cache, serial in-order Wishbone, no external atomic/coherent master',
            'capacity_test': {'bytes': CAPACITY_BYTES, 'address_lines_byte_bits': [2, 24],
                'mib_stride': 0x100000, 'end_word': DDR_CODE + CAPACITY_BYTES - 4,
                'pattern_seeds': [CAPACITY_SEED, CAPACITY_SEED ^ 0xffffffff],
                'eviction_bytes': 1024, 'runs_from_ROM_before_payload_copy': True,
                'coverage': 'Sparse address/capacity check, not an exhaustive every-cell memory test'},
            'fence_note': 'FENCE is NOP in current core; serial MMIO read drains stores before FENCE.I plus 3 NOPs'}
    (OUT / 'firmware.json').write_text(json.dumps(meta, indent=2) + '\n', encoding='ascii')
    print(json.dumps(meta, indent=2))


if __name__ == '__main__':
    main()
