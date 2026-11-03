"""Current work_B functional architecture using native editable Visio shapes."""
from pathlib import Path
import copy
import gc
import hashlib
import importlib.util
import json
import re
import sys
import traceback
import zipfile
import xml.etree.ElementTree as ET
import pythoncom
import win32com.client
import win32process

ROOT=Path(__file__).parent
B=Path(r'C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B')
SKILL=Path(r'C:\Users\lx292\.codex\skills\visio-skill')
RUN=ROOT/'.visio-runs'/'b_board_architecture'
RUN.mkdir(parents=True,exist_ok=True)
OUTPUT=ROOT/'B板整体架构图.vsdx'
SPEC_PATH=OUTPUT.with_suffix('.json')
if OUTPUT.exists(): raise FileExistsError(OUTPUT)

def load(name,path):
    s=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(s);sys.modules[name]=m;s.loader.exec_module(m)
    return m

sys.path.insert(0,str(SKILL/'scripts'))
engine=load('b_arch_engine',SKILL/'scripts'/'New-VisioDiagram.py')
parser=load('b_arch_parser',SKILL/'scripts'/'verilog_to_visio.py')
PROJECT=B/'td_project'/'camera_to_dsi_display_lidar.al'
source_section=re.search(r'<Source_Files>.*?</Source_Files>',PROJECT.read_text(encoding='utf-8'),re.S).group()
project_xml=ET.fromstring(re.sub(r'&(?!amp;|lt;|gt;|quot;|apos;)', '&amp;', source_section))
paths=[]
for f in project_xml.findall('.//Verilog/File'):
    attrs={a.get('Name'):a.get('Val') for a in f.findall('FileInfo/Attr')}
    if attrs.get('UsedInSyn')=='true' and attrs.get('AutoExcluded')!='true':
        p=(PROJECT.parent/f.get('Path')).resolve()
        if p.is_file(): paths.append(p)
mods=parser.parse_modules(paths)
auto=parser.build_spec(mods['design_top_wrapper'],mods)
(RUN/'rtl-automatic.json').write_text(json.dumps(auto,ensure_ascii=False,indent=2),encoding='utf-8')
# The automatic hierarchy includes diagnostics and alternative generate branches.
# Summarize the active functional paths and cross-hierarchy software boot here.
BLUE,ORANGE,WHITE,INK='#CBE5FE','#FFCB99','#FFFFFF','#202020'
W,H=36,26
page={'name':'B板整体架构','nodes':[],'labels':[],'connections':[]}
plan={'page':{'name':page['name'],'width':W,'height':H},'shapes':[],'connectors':[]}

def box(sid,x,y,w,h,text='',fill=ORANGE,size=17,container=False):
    page['nodes'].append(dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,shape='roundrect',
        fill=fill,line=INK,fontName='Microsoft YaHei',fontSize=size,container=container))
    plan['shapes'].append(dict(id=sid,x=x,y=y,width=w,height=h,text=text,kind='rectangle',
        shapeIntent='container' if container else 'module'))

def label(sid,x,y,w,h,text,size=15):
    page['labels'].append(dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,
        fontName='Microsoft YaHei',fontSize=size))
    plan['shapes'].append(dict(id=sid,x=x,y=y,width=w,height=h,text=text,kind='text'))

def edge(sid,a,b,fp=(1,.5),tp=(0,.5),both=False,dashed=False,corners=()):
    lookup={s['id']:s for s in plan['shapes']}
    def p(s,port):
        return [s['x']+(port[0]-.5)*s['width'],s['y']+(port[1]-.5)*s['height']]
    pts=p(lookup[a],fp)+[v for xy in corners for v in xy]+p(lookup[b],tp)
    c=dict(id=sid,**{'from':a,'to':b},fromX=fp[0],fromY=fp[1],toX=tp[0],toY=tp[1],
        line=INK,lineWeight=.75,endArrow=4,beginArrow=4 if both else 0,
        dashed=dashed,text='',kind='dynamic',points=pts)
    page['connections'].append(c);plan['connectors'].append(copy.deepcopy(c))

# White margins are part of the page; blue panels are functional groups only.
box('video_region',18,19.85,34.2,8.9,fill=BLUE,container=True)
box('linux_region',9.45,11.45,17.1,6.7,fill=BLUE,container=True)
box('memory_region',26.95,11.45,16.3,6.7,fill=BLUE,container=True)
box('rescue_region',18,4.3,34.2,6.1,fill=BLUE,container=True)
label('title',18,25.05,33,.6,'B 板整体架构图',30)
label('video_heading',18,23.75,32,.45,'① 本地视觉、A 板视频接收与 HDMI 显示',22)
label('linux_heading',8.7,14.25,14.3,.45,'② RISC-V / Linux 与无线通信',21)
label('memory_heading',31.8,14.25,6,.45,'③ 共享 DDR 与云图',20)
label('rescue_heading',5,6.85,7,.45,'④ 多传感器救援控制与执行机构',21)

box('camera',3.7,22,4.2,1.9,'SC500 摄像头\nMIPI CSI-2 / RAW10\nI²C 初始化与曝光配置',WHITE)
box('capture',9.3,22,4.2,1.9,'MIPI 接收与 RAW 解包\nCSI-2 → RAW10 → AXI4-S\n帧首保护 / SOF / 行尾')
box('isp',14.9,22,4.2,1.9,'ISP 图像前端\nBGGR 去马赛克 / 白平衡\n自动曝光统计与 I²C 更新\nisp_top / auto_exposure',size=16)
box('local_video',20.5,22,4.2,1.9,'本地视频缓存接口\n采集 / 读出 FIFO 与 CDC\n视频帧写入与显示取流\nvideo_in / video_out',size=16)
box('effects',26.1,22,4.2,1.9,'本地图像处理与识别\n均衡化 / 中值 / Sobel / 卡通\n运动区域 / 帧差；C7 切换\n独立 HSV 黄 / 绿检测旁路',size=16)
box('selector',31.7,22,4.2,1.9,'显示源选择\nSW2 / B4：高本地、低网络\n20 ms 去抖；帧消隐提交\nnetwork_display_select_reg',size=16)
box('a_board',3.7,18,4.2,2,'A 板视频与 NPU 结果\n640 × 360 RGB565\n人员框 / 来源帧号 / 结果 ID\n千兆以太网 UDP v3',WHITE,size=16)
box('eth_rx',9.3,18,4.2,2,'RGMII / UDP 接收\n包序 / 长度校验与像素重组\n异常丢帧 / 元数据提取\nethernet_video_rx_top',size=16)
box('net_video',14.9,18,4.2,2,'网络帧缓存接口\n完整帧提交；元数据随帧\n双缓冲 / 2 × 2 重复显示\nethernet_video_ddr_framebuffer',size=14.5)
box('osd',26.1,18,4.2,2,'OSD 与图层叠加\n黄 / 绿框、人员框、Logo\n距离 / 心率 / 血氧 / FPS\nLinux 云图叠加',size=16.5)
box('hdmi',31.7,18,4.2,2,'HDMI 显示输出\n1280 × 720\n像素时钟 75 MHz\nTMDS / u_hdmi_tx',WHITE,size=17)
label('network_note',19.25,19.15,1.8,.65,'网络视频\n上送显示源选择',12)

box('flash',3.7,12.1,4.2,2.1,'U33 合并 Flash 镜像\nFPGA 配置 + SBI / Linux\n+ MCU 读取服务固件\n上电配置与软件载荷共存',WHITE,size=16)
box('flash_service',9.3,12.1,4.2,2.1,'硬 MCU / AHB 读服务\nU33 XIP → Flash 读取桥\n供软核 ROM Loader 读取\ncpu_u33_flash_bridge',size=16)
box('cpu',14.9,12.1,4.2,2.1,'VexRiscv / Linux 子系统\nRV32IMA · Sv32 MMU\nROM Loader → SBI → Linux\nWishbone / timer / UART',size=16)
box('pc_lidar',3.7,9.5,4.2,1.6,'PC / 雷达数据源\nL150 采集与云图生成\nSSH 发送 / 远程终端',WHITE,size=16)
box('wifi',9.3,9.5,4.2,1.6,'ESP32 Wi-Fi 通信\nWi-Fi ↔ UART / PPP\nLinux SSH / 云图数据',WHITE,size=16)
label('loader_note',14.6,8.75,5.2,.4,'ROM Loader 校验载荷并装入 DDR',12)

box('ddr_arb',23.25,12.1,7.3,2.1,'视频 / CPU 共享 DDR 访问\nethernet_video_ddr_mux：本地 / 网络合并\nCPU 字服务 / CDC → ddr_video_cpu_arbiter\n视频优先仲裁；存储分区保护',size=16)
box('ddr',31.7,12.1,4.2,2.1,'DDR 控制器与存储器\n原生用户端口 128 位\n本地 / 网络视频独立分区\nLinux / CPU 运行分区',WHITE,size=16)
box('cloud',23.25,9.5,7.3,1.55,'Linux 云图 MMIO / 双页缓存 / CDC\n0xF0020000 · 201 × 201 点阵\nlidar_map_overlay → HDMI 图层',size=16)
label('memory_note',31.4,9.55,4.5,1,'CPU 可见 DDR：32 MiB\nCPU 地址：0x40000000 起\n视频与 CPU 访问共享物理 DDR',13)

box('range',3.7,5.25,4.2,1.8,'HC-SR04-2020 测距\nTRIG / ECHO → 距离 / 有效位\nhcsr04_2020_ranging',WHITE,size=16)
box('sensors',9.3,5.25,4.2,1.8,'检测结果汇聚 / 跨时钟\n黄 / 绿目标 + A 板人员框\n距离 / 新鲜度 / 故障状态\nrescue_sensor_mailbox',size=16)
box('control',14.9,5.25,4.2,1.8,'救援任务与动作互锁\n绿色抓取 / 人员停车\n黄色火焰许可 / 手自动切换\nrescue_control',size=16)
box('medical',3.7,2.65,4.2,1.65,'MAX30102 生理采集\nI²C → 心率 / 血氧\nmax30102_top / osd_cdc',WHITE,size=16)
box('buttons',9.3,2.65,4.2,1.65,'按键 / 开关输入\n任务手自动切换\n机械臂选关节 / 步进调节',WHITE,size=16)
box('voice',14.9,2.65,4.2,1.65,'语音提示 UART\n火焰 01 / 绿色 03 / 人员 04\nvoice_alert_uart_tx',size=16)
box('car',20.5,3.3,4.2,2.15,'小车运动控制\n前进 / 后退 / 转向 / 停车\nUART 9600 · 50 ms 刷新\nc30d_motion_tx\n→ 小车控制器',size=16)
box('arm',26.1,3.3,4.2,2.15,'六路机械臂控制\n距离定位抓取 / 回位\n手动调节 / 自动占用互锁\narm_distance_position_auto\nservo_pwm6 → 6 路 PWM',size=15.5)
box('fire',31.7,3.3,4.2,2.15,'自动灭火控制\n黄色目标确认 / 舵机瞄准\n稳定等待 / 喷水限时 / 再触发\nfire_servo_position / spray\n→ 瞄准舵机 PWM / 水泵 GPIO',size=15.5)
label('actuator_bus',26.1,5.8,15,.35,'任务命令 / 动作许可 / 资源互锁',15)
label('basis',18,.7,34,.55,'依据当前 B 板 work_B / camera_to_dsi_display_lidar RTL 与配套软件整理；本图为功能架构，时钟与复位统一分发。\n实线：图像 / 存储 / 软件数据通路；虚线：检测结果 / 状态 / 执行控制。',12)

for a,b in [('camera','capture'),('capture','isp'),('isp','local_video'),('local_video','effects'),
            ('effects','selector'),('a_board','eth_rx'),('eth_rx','net_video'),('osd','hdmi'),
            ('flash','flash_service'),('flash_service','cpu')]:
    edge(a+'_to_'+b,a,b)
edge('isp_sensor_config','isp','camera',(.5,1),(.5,1),dashed=True,
     corners=[(14.9,23.25),(3.7,23.25)])
edge('network_to_selector','net_video','selector',(1,.65),(0,.4),
     corners=[(18.0,18.3),(18.0,20.35),(28.8,20.35),(28.8,21.81)])
edge('selected_video_to_osd','selector','osd',(.5,0),(.5,1),
     corners=[(31.7,19.8),(26.1,19.8)])
edge('local_ddr_access','local_video','ddr_arb',(.5,0),(.66,1),both=True,
     corners=[(20.5,15.1),(24.418,15.1)])
edge('network_ddr_access','net_video','ddr_arb',(.5,0),(.35,1),both=True,
     corners=[(14.9,15.65),(22.155,15.65)])
edge('cpu_ddr_access','cpu','ddr_arb',both=True)
edge('arbiter_to_ddr','ddr_arb','ddr',both=True)
edge('pc_wifi','pc_lidar','wifi',both=True)
edge('wifi_cpu','wifi','cpu',(1,.5),(.5,0),both=True,corners=[(14.9,9.5)])
edge('cpu_map_mmio','cpu','cloud',(1,.2),(0,.5),both=True,
     corners=[(18.4,11.47),(18.4,9.5)])
edge('map_osd','cloud','osd',(1,.5),(.65,0),
     corners=[(28.15,9.5),(28.15,16.35),(26.73,16.35)])
edge('range_mailbox','range','sensors',dashed=True)
edge('sensor_control','sensors','control',dashed=True)
# Separate corridors preserve the independent local HSV and received NPU paths.
edge('hsv_to_mailbox','effects','sensors',(.22,0),(.5,1),dashed=True,
     corners=[(24.924,20.0),(17.75,20.0),(17.75,7.7),(9.3,7.7)])
edge('npu_to_mailbox','eth_rx','sensors',(.5,0),(.65,1),dashed=True,
     corners=[(9.3,16.45),(17.3,16.45),(17.3,7.95),(9.93,7.95)])
edge('medical_osd','medical','osd',(0,.5),(.28,0),dashed=True,
     corners=[(1.2,2.65),(1.2,16.1),(25.176,16.1)])
edge('manual_control','buttons','control',(.5,1),(0,.23),dashed=True,
     corners=[(9.3,3.85),(12.2,3.85),(12.2,4.764)])
edge('controller_voice','control','voice',(.5,0),(.5,1),dashed=True)
for a,x in [('car',20.5),('arm',26.1),('fire',31.7)]:
    edge('control_'+a,'control',a,(1,.5),(.5,1),dashed=True,corners=[(x,5.25)])

SPEC={'title':'B 板整体架构图','pageWidth':W,'pageHeight':H,'pages':[page]}
SPEC_PATH.write_text(json.dumps(SPEC,ensure_ascii=False,indent=2),encoding='utf-8')
(RUN/'layout-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
layout=load('b_arch_layout',Path(r'C:\Users\lx292\.codex\skills\visio-template-drawing\scripts\validate_plan_layout.py'))
findings=layout.validate_page(plan)
(RUN/'preflight.json').write_text(json.dumps(findings,ensure_ascii=False,indent=2),encoding='utf-8')
if findings: raise RuntimeError(json.dumps(findings,ensure_ascii=False,indent=2))

sources=[PROJECT]+paths+[B/'firmware/linux_wifi/lidar_hdmi/README.md']
report={'output':str(OUTPUT),'spec':str(SPEC_PATH),'skill':str(SKILL/'SKILL.md'),
    'project':str(PROJECT),'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    'rtl_modules_parsed':len(mods),'rtl_top_instances':len(mods['design_top_wrapper'].instances),
    'preflight_findings':findings,'status':'started','hardware_builds_performed':False}
pythoncom.CoInitialize()
app=doc=vpage=shape=connector=window=candidate=None
objects={};kept=False
try:
    app=win32com.client.DispatchEx('Visio.Application')
    app.Visible=False;app.EventsEnabled=False;app.AlertResponse=2
    report['owned_pid']=win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]
    doc=app.Documents.Add('');vpage=doc.Pages.Item(1);vpage.Name=page['name']
    vpage.PageSheet.CellsU('PageWidth').ResultIU=W
    vpage.PageSheet.CellsU('PageHeight').ResultIU=H
    for n in page['nodes']:
        shape=engine.add_node(vpage,n,{});shape.NameU=n['id']
        for k,v in {'Rounding':'0.08 in','LineWeight':'0.65 pt','Char.Color':'RGB(0,0,0)',
                    'Char.Style':'0','Char.AsianFont':'FONT("Microsoft YaHei")'}.items():
            shape.CellsU(k).FormulaU=v
        objects[n['id']]=shape
    for c in page['connections']:
        engine.add_connection(app,vpage,objects,c)
        connector=vpage.Shapes.Item(vpage.Shapes.Count);connector.NameU=c['id']
        connector.CellsU('BeginX').GlueToPos(objects[c['from']],c['fromX'],c['fromY'])
        connector.CellsU('EndX').GlueToPos(objects[c['to']],c['toX'],c['toY'])
        connector.CellsU('EndArrowSize').FormulaU='0';connector.CellsU('BeginArrowSize').FormulaU='0'
        if c['dashed']: connector.CellsU('LinePattern').FormulaU='2'
    for l in page['labels']:
        shape=engine.add_label(vpage,l);shape.NameU=l['id']
        for k,v in {'FillPattern':'0','LinePattern':'0','Char.Color':'RGB(0,0,0)',
                    'Char.Style':'0','Char.AsianFont':'FONT("Microsoft YaHei")'}.items():
            shape.CellsU(k).FormulaU=v
        objects[l['id']]=shape
    assert doc.Pages.Count==1 and vpage.Connects.Count==2*len(page['connections'])
    for n in page['nodes']+page['labels']:
        assert objects[n['id']].Text.rstrip('\r\n')==n['text'].rstrip('\r\n')
    for i in range(1,app.Windows.Count+1):
        candidate=app.Windows.Item(i)
        if candidate.Type==1 and candidate.Document.ID==doc.ID: window=candidate;break
    if window is None: raise RuntimeError('Drawing window not found')
    window.ShowGrid=False;window.ShowPageBreaks=False;window.ShowGuides=False;window.ViewFit=1
    doc.SaveAs(str(OUTPUT))
    assert doc.Saved and OUTPUT.stat().st_size>0
    with zipfile.ZipFile(OUTPUT) as z:
        assert z.testzip() is None and not any(n.startswith('visio/media/') for n in z.namelist())
    app.Settings.SetRasterExportResolution(0,80,80,0)
    preview=RUN/'preview.png';vpage.Export(str(preview))
    report.update(status='complete',pages=1,native_shapes=vpage.Shapes.Count,
        glued_connectors=len(page['connections']),glued_endpoints=vpage.Connects.Count,
        texts_verified=True,grid=bool(window.ShowGrid),page_breaks=bool(window.ShowPageBreaks),
        preview=str(preview),file_bytes=OUTPUT.stat().st_size)
    app.EventsEnabled=True;app.AlertResponse=0;app.Visible=True
    window.Activate();window.ViewFit=1;kept=True;report['final_window_retained']=True
except Exception:
    report.update(status='failed',error=traceback.format_exc());raise
finally:
    (RUN/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    if not kept:
        if doc is not None: doc.Saved=True;doc.Close()
        if app is not None: app.Quit()
    objects.clear();shape=connector=candidate=window=vpage=doc=app=None
    gc.collect();pythoncom.CoUninitialize()
print(json.dumps({k:v for k,v in report.items() if k!='source_hashes'},ensure_ascii=False,indent=2))
