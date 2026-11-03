"""Editable, source-grounded B-board RISC-V/Linux architecture, visio-skill."""
from pathlib import Path
import copy
import gc
import hashlib
import importlib.util
import json
import sys
import traceback
import zipfile

import pythoncom
import win32com.client
import win32process

ROOT=Path(__file__).parent
BOARD=Path(r'C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B')
SKILL=Path(r'C:\Users\lx292\.codex\skills\visio-skill')
RUN=ROOT/'.visio-runs'/'riscv_linux_boot_architecture'
RUN.mkdir(parents=True,exist_ok=True)
OUTPUT=ROOT/'RISC-V软核CPU与Linux启动架构图.vsdx'
if OUTPUT.exists():
    raise FileExistsError(OUTPUT)

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    obj=importlib.util.module_from_spec(spec)
    sys.modules[name]=obj
    spec.loader.exec_module(obj)
    return obj

sys.path.insert(0,str(SKILL/'scripts'))
engine=module('boot_visio_engine',SKILL/'scripts'/'New-VisioDiagram.py')
parser=module('boot_rtl_parser',SKILL/'scripts'/'verilog_to_visio.py')
RTL=BOARD/'td_project'/'import'/'vexriscv_b'
SUB=BOARD/'firmware'/'linux_wifi'/'lidar_hdmi'/'rtl'
FLASH=BOARD/'firmware'/'linux_wifi_flash'
sources=[SUB/'design_top_wrapper.v',SUB/'vexriscv_b_subsystem.v',
    RTL/'vexriscv_linux_top.v',RTL/'vexriscv_b_memory.v',RTL/'cpu_wb_decoder.v',
    RTL/'cpu_wb_ddr_bridge.v',RTL/'cpu_ddr_cdc.v',RTL/'cpu_ddr_word_service.v',
    RTL/'ddr_video_cpu_arbiter.v',RTL/'linux_timer.v',RTL/'cpu_uart.v',
    FLASH/'build'/'rtl'/'cpu_u33_flash_bridge.v',
    FLASH/'build'/'rtl'/'vexriscv_b_boot_rom.v',
    BOARD/'firmware'/'linux_wifi'/'rtl'/'wifi_uart_wb.v']
mods=parser.parse_modules(sources)
# Auto-extract the actual hierarchy, then summarize the cross-hierarchy boot
# firmware and shared-memory path into the functional architecture below.
auto=parser.build_spec(mods['vexriscv_b_subsystem'],mods)
(RUN/'rtl-automatic.json').write_text(json.dumps(auto,ensure_ascii=False,indent=2),encoding='utf-8')

BLUE,ORANGE,WHITE,INK='#CBE5FE','#FFCB99','#FFFFFF','#202020'
page={'name':'RISC-V与Linux启动','nodes':[],'labels':[],'connections':[],'lines':[]}
plan={'page':{'name':page['name'],'width':30,'height':20.6},'shapes':[],'connectors':[]}

def box(sid,x,y,w,h,text='',fill=ORANGE,container=False,size=17):
    page['nodes'].append(dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,
        shape='roundrect',fill=fill,line=INK,fontName='Microsoft YaHei',fontSize=size,
        container=container))
    plan['shapes'].append(dict(id=sid,x=x,y=y,width=w,height=h,text=text,
        kind='rectangle',shapeIntent='container' if container else 'module'))

def label(sid,x,y,w,h,text,size=15):
    page['labels'].append(dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,
        fontName='Microsoft YaHei',fontSize=size))
    plan['shapes'].append(dict(id=sid,x=x,y=y,width=w,height=h,text=text,kind='text'))

def edge(sid,a,b,fp=(1,.5),tp=(0,.5),both=False,dash=False,corners=()):
    lookup={s['id']:s for s in plan['shapes']}
    def endpoint(s,p):
        return [s['x']+(p[0]-.5)*s['width'],s['y']+(p[1]-.5)*s['height']]
    start=endpoint(lookup[a],fp);end=endpoint(lookup[b],tp)
    pts=start+[v for xy in corners for v in xy]+end
    c=dict(id=sid,**{'from':a,'to':b},fromX=fp[0],fromY=fp[1],toX=tp[0],toY=tp[1],
           kind='dynamic',line=INK,lineWeight=.75,endArrow=4,beginArrow=4 if both else 0,
           dashed=dash,text='',points=pts)
    page['connections'].append(c)
    plan['connectors'].append(copy.deepcopy(c))

box('flash_region',5.15,12.25,8.6,12.5,fill=BLUE,container=True)
box('cpu_region',14.75,12.25,9.4,12.5,fill=BLUE,container=True)
box('ddr_region',24.6,12.25,9.1,12.5,fill=BLUE,container=True)
box('boot_region',15,3.25,28.3,4.8,fill=BLUE,container=True)
label('title',15,19.45,28,.6,'RISC-V 软核 CPU 与 Linux 启动架构图',29)
label('flash_heading',5.15,18,8,.45,'① U33 Flash 与读取服务',21)
label('cpu_heading',14.75,18,8.8,.45,'② RISC-V 软核与片上总线',21)
label('ddr_heading',24.6,18,8.5,.45,'③ 共享 DDR 访问路径',21)
label('boot_heading',15,5.2,27,.45,'④ 上电至 Linux 用户态的启动顺序',21)

box('flash',5.15,16,7.2,2.5,
    'U33 配置 Flash · 16 MiB\nFPGA 配置：0x00000000\nVRD1 + SBI / Linux：0x00200000\nMCU 读服务固件：0x00E00000',WHITE)
box('mcu',5.15,13.2,6.7,1.6,
    '硬 MCU · Flash XIP 读取服务\n100 MHz；按请求读取 32 位字\nu_linux_flash_mcu')
box('flash_bridge',5.15,10.5,6.7,1.75,
    'Wishbone / AHB 只读桥\nCPU 发起读请求；MCU 返回数据\nToggle CDC / 超时检测\ncpu_u33_flash_bridge')
label('flash_note',5.15,7.65,7.3,1.5,
    '配置与软件载荷合并存储于 U33\nMCU 提供读服务\nROM Loader 负责向 DDR 复制',16)

box('cpu',14.75,15.75,7.5,2.3,
    'VexRiscv 软核 CPU\nRV32IMA · M/S/U · Sv32 MMU\nI-cache / D-cache / CSR\n50 MHz；复位入口 0x00000000')
box('wb',14.75,12.6,7.5,1.3,
    'Wishbone 指令 / 数据总线\n地址译码与应答选择\ncpu_wb_decoder / subsystem',size=16)
box('rom',12.55,10,3.25,1.8,
    '启动 ROM（4 KiB）\n特权 / MMU / DDR32自检\nLoader / 串口恢复',size=15)
box('clint',17,10,3.4,1.8,
    'CLINT 定时器\n0xF0010000\n定时 / 软件中断\nlinux_timer',size=15)
box('io',14.75,7.55,7.5,1.6,
    'MMIO 外设接口\n控制台 UART：0xF0001100\nWi-Fi UART：0xF0001200\n云图接口：0xF0020000',WHITE,size=16)

box('ddr_bridge',24.6,15.75,7.3,1.8,
    'Wishbone-DDR 桥与跨时钟\ncpu_wb_ddr_bridge / cpu_ddr_cdc\n50 MHz CPU 域 ↔ DDR 时钟域',size=16)
box('arbiter',24.6,12.6,7.3,1.8,
    'DDR 字服务与视频 / CPU 仲裁\ncpu_ddr_word_service\nddr_video_cpu_arbiter\n分区保护；视频优先且限制等待',size=16)
box('ddr',24.6,9,7.3,3.6,
    '共享 DDR / CPU 运行分区\nCPU 可见容量：32 MiB\n0x40000000—0x41FFFFFF\nSBI 载入与入口：0x40100000\nLinux Image：0x40400000\nDDR 控制器原生数据宽度：128 位',WHITE,size=16)

stages=[
    ('power',3.25,'上电与复位\nFPGA 从 Flash 配置\n时钟锁定后释放 CPU'),
    ('selftest',7.95,'ROM 自检\nMMU / 特权级检查\nDDR32 自检'),
    ('header',12.65,'读取并校验包头\nVRD1 / 长度 / 地址\nHeader CRC32'),
    ('copy',17.35,'载荷装入 DDR\nCPU 复制、驱逐 D-cache\nDDR CRC / FENCE.I'),
    ('sbi',22.05,'SBI 固件（M 模式）\n入口 0x40100000\n传递 DTB；进入 S 模式'),
    ('linux',26.75,'Linux 与用户态\n内核 0x40400000\ninitramfs / PPP / SSH')]
for sid,x,text in stages:
    box('boot_'+sid,x,3.65,4,1.8,text,WHITE if sid in ['power','linux'] else ORANGE,size=15.5)
label('boot_failure',15,1.75,27,.55,
    '包头 / 地址范围 / CRC 错误，或 Flash 读超时 → ROM 串口恢复菜单；校验通过后才跳转',16)
label('basis',15,1.1,28,.3,'依据 B 板 work_B 当前 RTL 与启动固件整理；硬件连接与软件启动过程按功能分组。',13)
label('ibus_label',12.1,13.9,1.8,.35,'I-bus · 32 位',13)
label('dbus_label',17.45,13.9,1.8,.35,'D-bus · 32 位',13)
label('irq_label',19.7,13.8,.8,.35,'IRQ',13)

edge('flash_xip','flash','mcu',(.5,0),(.5,1))
edge('mcu_ahb','mcu','flash_bridge',(.5,0),(.5,1),both=True)
edge('flash_wb','flash_bridge','wb',(1,.5),(0,.5),both=True,corners=[(9.8,10.5),(9.8,12.6)])
edge('ibus','cpu','wb',(.32,0),(.32,1),both=True)
edge('dbus','cpu','wb',(.68,0),(.68,1),both=True)
edge('rom_bus','wb','rom',((12.55-11)/7.5,0),(.5,1),both=True)
edge('timer_bus','wb','clint',((17-11)/7.5,0),(.5,1),both=True)
edge('io_bus','wb','io',(.5,0),(.5,1),both=True)
edge('ddr_bus','wb','ddr_bridge',(1,.5),(0,.5),both=True,corners=[(19.75,12.6),(19.75,15.75)])
edge('ddr_cdc_to_arb','ddr_bridge','arbiter',(.5,0),(.5,1),both=True)
edge('arb_to_ddr','arbiter','ddr',(.5,0),(.5,1),both=True)
# Interrupt is a deliberately routed editable line in its reserved corridor.
irq_pts=[18.7,10,19.2,10,19.2,16.21,18.5,16.21]
page['lines'].append(dict(id='irq',points=irq_pts,line=INK,lineWeight=.7,dashed=True,endArrow=4))
plan['connectors'].append(dict(id='irq',**{'from':'clint','to':'cpu'},points=irq_pts))
for a,b in zip(stages,stages[1:]):
    edge('seq_'+a[0],'boot_'+a[0],'boot_'+b[0])

SPEC={'title':'RISC-V 软核 CPU 与 Linux 启动架构图','pageWidth':30,'pageHeight':20.6,'pages':[page]}
(ROOT/'RISC-V软核CPU与Linux启动架构图.json').write_text(json.dumps(SPEC,ensure_ascii=False,indent=2),encoding='utf-8')
(RUN/'layout-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
layout=module('boot_layout_check',Path(r'C:\Users\lx292\.codex\skills\visio-template-drawing\scripts\validate_plan_layout.py'))
findings=layout.validate_page(plan)
if findings:
    raise RuntimeError(json.dumps(findings,ensure_ascii=False,indent=2))

evidence={'output':str(OUTPUT),'skill':str(SKILL/'SKILL.md'),
    'project':str(BOARD/'td_project'/'camera_to_dsi_display_lidar.al'),
    'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    'firmware_sources':[str(FLASH/'build.py'),str(BOARD/'firmware'/'vexriscv_sbi'/'firmware.ld'),
        str(BOARD/'firmware'/'linux_wifi'/'linux'/'board.dts')],
    'preflight_findings':findings,'status':'started','hardware_builds_performed':False}
pythoncom.CoInitialize()
app=doc=vpage=shape=connector=window=candidate=None
objects={}
kept=False
try:
    app=win32com.client.DispatchEx('Visio.Application')
    app.Visible=False
    app.EventsEnabled=False
    app.AlertResponse=2
    evidence['owned_pid']=win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]
    doc=app.Documents.Add('')
    vpage=doc.Pages.Item(1)
    vpage.Name=page['name']
    vpage.PageSheet.CellsU('PageWidth').ResultIU=30
    vpage.PageSheet.CellsU('PageHeight').ResultIU=20.6
    for node in page['nodes']:
        shape=engine.add_node(vpage,node,{})
        shape.NameU=node['id']
        shape.CellsU('Rounding').FormulaU='0.09 in'
        shape.CellsU('LineWeight').FormulaU='0.65 pt'
        shape.CellsU('Char.Color').FormulaU='RGB(0,0,0)'
        shape.CellsU('Char.Style').FormulaU='0'
        objects[node['id']]=shape
    for c in page['connections']:
        engine.add_connection(app,vpage,objects,c)
        connector=vpage.Shapes.Item(vpage.Shapes.Count)
        connector.NameU=c['id']
        connector.CellsU('BeginX').GlueToPos(objects[c['from']],c['fromX'],c['fromY'])
        connector.CellsU('EndX').GlueToPos(objects[c['to']],c['toX'],c['toY'])
        connector.CellsU('EndArrowSize').FormulaU='0'
        connector.CellsU('BeginArrowSize').FormulaU='0'
        if c.get('dashed'):
            connector.CellsU('LinePattern').FormulaU='2'
        connector=None
    for line in page['lines']:
        shape=vpage.DrawPolyline(line['points'],0)
        shape.NameU=line['id']
        shape.CellsU('FillPattern').FormulaU='0'
        shape.CellsU('LineColor').FormulaU='RGB(32,32,32)'
        shape.CellsU('LineWeight').FormulaU='0.7 pt'
        shape.CellsU('LinePattern').FormulaU='2'
        shape.CellsU('EndArrow').FormulaU='4'
        shape.CellsU('EndArrowSize').FormulaU='0'
    for l in page['labels']:
        shape=engine.add_label(vpage,l)
        shape.NameU=l['id']
        shape.CellsU('FillPattern').FormulaU='0'
        shape.CellsU('LinePattern').FormulaU='0'
        shape.CellsU('Char.Color').FormulaU='RGB(0,0,0)'
        objects[l['id']]=shape
    assert doc.Pages.Count==1
    assert vpage.Connects.Count==len(page['connections'])*2
    for row in page['nodes']+page['labels']:
        assert objects[row['id']].Text.rstrip('\r\n')==row['text'].rstrip('\r\n')
    for i in range(1,app.Windows.Count+1):
        candidate=app.Windows.Item(i)
        if candidate.Type==1 and candidate.Document.ID==doc.ID:
            window=candidate
            break
    if window is None:
        raise RuntimeError('Drawing window not found')
    window.ShowGrid=False
    window.ShowPageBreaks=False
    window.ShowGuides=False
    window.ViewFit=1
    doc.SaveAs(str(OUTPUT))
    assert doc.Saved and OUTPUT.stat().st_size>0
    with zipfile.ZipFile(OUTPUT) as z:
        assert z.testzip() is None
        assert not any(n.startswith('visio/media/') for n in z.namelist())
    preview=RUN/'preview.png'
    app.Settings.SetRasterExportResolution(0,85,85,0)
    vpage.Export(str(preview))
    evidence.update(status='complete',pages=doc.Pages.Count,native_shapes=vpage.Shapes.Count,
        glued_connectors=len(page['connections']),glued_endpoints=vpage.Connects.Count,
        editable_irq_route=True,texts_verified=True,grid=bool(window.ShowGrid),
        page_breaks=bool(window.ShowPageBreaks),preview=str(preview),file_bytes=OUTPUT.stat().st_size)
    app.EventsEnabled=True
    app.AlertResponse=0
    app.Visible=True
    window.Activate()
    window.ViewFit=1
    kept=True
    evidence['final_window_retained']=True
except Exception:
    evidence.update(status='failed',error=traceback.format_exc())
    raise
finally:
    (RUN/'result.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    if not kept:
        if doc is not None:
            doc.Saved=True
            doc.Close()
        if app is not None:
            app.Quit()
    objects.clear()
    shape=connector=candidate=window=vpage=doc=app=None
    gc.collect()
    pythoncom.CoUninitialize()
print(json.dumps({k:v for k,v in evidence.items() if k!='source_hashes'},ensure_ascii=False,indent=2))
