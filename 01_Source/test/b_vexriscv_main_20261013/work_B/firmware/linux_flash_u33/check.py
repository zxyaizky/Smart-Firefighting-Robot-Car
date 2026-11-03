"""Host checks and four-state bridge simulation; never opens COM or programs hardware."""
from pathlib import Path
import hashlib,json,re,struct,subprocess,sys
import build
import pack_flash

F=build.F;W=build.W;R=build.R
SIM=R/'sim';TOOLS=Path('D:/BaiduNetdiskDownload/win64')

def run(name,args,timeout=180):
    SIM.mkdir(parents=True,exist_ok=True)
    result=subprocess.run([a.as_posix() if isinstance(a,Path) else str(a) for a in args],cwd=SIM,capture_output=True,text=True,errors='replace',timeout=timeout)
    text=result.stdout+result.stderr
    build.put(SIM/(name+'.log'),text)
    if result.returncode or re.search(r'\*\* (Error|Fatal)|\bFAIL\b',text):raise RuntimeError(text[-6000:])
    return text

def firmware_check():
    # Execute every instruction of the actual 32-byte MCU firmware. The hardware
    # primitive's QSPI electrical behavior is outside this instruction-level test.
    raw=(build.O/'u33_boot_fw.bin').read_bytes();words=struct.unpack('<8I',raw)
    registers=[0]*32;pc=0;served=[];polls=0
    source={0x20200000:0x12345678,0x207807c0:0x55aa55aa};requests=list(source)
    active=None
    for _ in range(500):
        instruction=words[pc//4];op=instruction&127
        rd=(instruction>>7)&31;rs1=(instruction>>15)&31;rs2=(instruction>>20)&31
        immediate=instruction>>20
        if immediate&0x800:immediate-=4096
        next_pc=pc+4
        if op==0x37:registers[rd]=instruction&0xfffff000
        elif op==0x13:registers[rd]=registers[rs1]&immediate
        elif op==0x03:
            address=(registers[rs1]+immediate)&0xffffffff
            if address==0x80000000:
                polls+=1
                if polls>2 and active is None and requests:active=requests.pop(0)
                value=int(active is not None)
            elif address==0x80000004:value=active
            else:value=source[address]
            registers[rd]=value
        elif op==0x23:
            offset=((instruction>>25)<<5)|((instruction>>7)&31)
            assert registers[rs1]+offset==0x80000008
            served.append((active,registers[rs2]));active=None
        elif op==0x63:
            offset=((instruction>>31)<<12)|(((instruction>>7)&1)<<11)|(((instruction>>25)&63)<<5)|(((instruction>>8)&15)<<1)
            if offset&4096:offset-=8192
            if registers[rs1]==registers[rs2]:next_pc=pc+offset
        elif op==0x6f:
            offset=((instruction>>31)<<20)|(((instruction>>12)&255)<<12)|(((instruction>>20)&1)<<11)|(((instruction>>21)&1023)<<1)
            if offset&0x100000:offset-=0x200000
            registers[rd]=pc+4;next_pc=pc+offset
        else:raise AssertionError(hex(instruction))
        registers[0]=0;pc=next_pc
        if len(served)==2:break
    assert served==list(source.items()),served
    return {'status':'PASS','responses':[[hex(a),hex(v)] for a,v in served],'hard_mcu_phy_simulated':False}

def static():
    project=W/'td_project/camera_to_dsi_display_linux_flash.al'
    tcl='''cd {PROJECT_DIR}
import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project {PROJECT}
load_run_param -run syn_1
commit_param -step design
elaborate -top design_top_wrapper
read_sdc {BASE_SDC}
read_sdc {FLASH_SDC}
set cpu [get_cells -nowarn {u_vexriscv_linux/cpu_top_inst/cpu_inst}]
set bridge [get_cells -hierarchical -nowarn {*flash_bridge_inst}]
set mcu [get_cells -nowarn {u_linux_flash_mcu}]
puts "COUNTS cpu=[llength $cpu] bridge=[llength $bridge] mcu=[llength $mcu]"
if {[llength $cpu] != 1 || [llength $bridge] != 1 || [llength $mcu] != 1} {error "Incomplete CPU/Flash hierarchy"}
puts "U33_FLASH_STATIC_PASS_NO_SYNTHESIS"
'''.replace('PROJECT_DIR',project.parent.as_posix()).replace('PROJECT',project.as_posix())
    tcl=tcl.replace('BASE_SDC',(W/'td_project/camera_to_dsi_display.sdc').as_posix())
    tcl=tcl.replace('FLASH_SDC',(F/'u33_flash.sdc').as_posix())
    script=R/'read_design.tcl'
    build.put(script,'if {[catch {\n'+tcl+'\n} why]} {puts stderr "U33_STATIC_FAIL $why"; exit 1}\nexit\n')
    output=run('td_read_design',['C:/Anlogic/bin/td_commands_prompt.exe',script],timeout=240)
    assert 'U33_FLASH_STATIC_PASS_NO_SYNTHESIS' in output,output[-5000:]
    assert not re.search(r'start command "(?:optimize|place|route|bitgen|download)',output)
    return {'status':'PASS','synthesis_or_route':False,'constraint_application_and_timing':'Pending synthesized netlist; Read Design attaches SDC only'}

def cpu_boot():
    boot=build.load(W/'vexriscv_linux_test/ddr_integration/generate_boot.py','encoders')
    program=boot.Program('flash_probe')
    program.li(20,0xf0001000);program.li(3,0x600df123);program.store(3,20,0x20)
    program.label('halt');program.jump('halt');program.finish()
    data=b''.join(struct.pack('<I',program.words[at][0]) for at in sorted(program.words))
    data=data.ljust(1024,b'\x5a')
    rom,p,words=build.make_boot(data)
    build.put(SIM/'vexriscv_b_boot_rom.v',rom)
    build.put(SIM/'flash_test.hex',''.join(f'{word[0]:08x}\n' for word in struct.iter_unpack('<I',data)))
    sources=[build.BASE/n for n in ['VexRiscv_Linux.v','vexriscv_linux_top.v',
        'vexriscv_b_memory.v','cpu_wb_decoder.v','cpu_wb_ddr_bridge.v','cpu_uart.v','linux_timer.v']]
    sources += [W/'td_project/import/us100_uart_rx.v',build.C/'vexriscv_b_subsystem.v',
        F/'rtl/cpu_u33_flash_bridge.v',SIM/'vexriscv_b_boot_rom.v',F/'sim/tb_flash_boot.v']
    run('compile_boot',[TOOLS/'vlog.exe','-O0',*sources])
    evidence=[]
    for mode in range(3):
        output=run('cpu_boot_'+str(mode),[TOOLS/'vsim.exe','-c','-novopt','-suppress','12110',
            'work.tb_flash_boot','+MODE='+str(mode),'-do','run -all; quit -f'],timeout=240)
        passed=[line for line in output.splitlines() if 'PASS flash_boot' in line]
        assert len(passed)==1,output[-5000:]
        evidence+=passed
    return dict(status='PASS',evidence=evidence,payload_bytes=len(data),
        scope='Real CPU reset/ROM/local memory/WB DDR bridge; behavioral MCU AHB and DDR models. Short test payload, not full Linux Flash boot.')

def main():
    result={'firmware':firmware_check()}
    config=b'\xa5'*65536;payload=(build.O/'linux_payload.bin').read_bytes()
    firmware=(build.O/'u33_boot_fw.bin').read_bytes()
    image=pack_flash.merge(config,payload,firmware)
    assert image[:len(config)]==config
    assert image[build.FLASH_OFFSET:build.FLASH_OFFSET+len(payload)]==payload
    assert image[build.MCU_OFFSET:]==firmware and len(image)<=build.FLASH_SIZE
    for parts in [(b'x'*(build.FLASH_OFFSET+1),payload,firmware),(config,b'',firmware),
                  (config,payload,b'x'*(build.FLASH_SIZE-build.MCU_OFFSET+1))]:
        try:pack_flash.merge(*parts)
        except ValueError:pass
        else:raise AssertionError('Invalid Flash layout accepted')
    result['layout']={'status':'PASS','bytes':len(image),'synthetic_config_not_for_programming':True}
    project=(W/'td_project/camera_to_dsi_display_linux_flash.al').read_text()
    refs=re.findall(r'<File Path="([^"]+)"',project)
    assert len(refs)==len(set(refs))
    missing=[p for p in refs if not Path(p).is_file()]
    assert not missing,missing
    assert '<Name>camera_to_dsi_display_linux_flash</Name>' in project
    result['manifest']={'status':'PASS','files':len(refs)}
    if not (SIM/'work').exists():run('vlib',[TOOLS/'vlib.exe','work'])
    run('compile_bridge',[TOOLS/'vlog.exe',F/'rtl/cpu_u33_flash_bridge.v',F/'sim/tb_flash_bridge.v'])
    log=run('bridge',[TOOLS/'vsim.exe','-c','-novopt','-suppress','12110','work.tb_flash_bridge','-do','run -all; quit -f'])
    assert 'PASS flash_bridge' in log,log[-5000:]
    result['bridge']={'status':'PASS','evidence':[line for line in log.splitlines() if 'PASS flash_bridge' in line]}
    if '--cpu' in sys.argv:result['cpu_boot']=cpu_boot()
    if '--static' in sys.argv:result['td_static']=static()
    frozen=json.loads((R/'protected_before.json').read_text())
    for name,digest in frozen.items():assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest,name
    result['protected_files_unchanged']=len(frozen)
    build.put(R/'checks.json',json.dumps(result,indent=2));print(json.dumps(result,indent=2))

if __name__=='__main__':main()
