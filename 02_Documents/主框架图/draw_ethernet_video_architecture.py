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
SKILL=Path(r'C:\Users\lx292\.codex\skills\visio-skill')
A=Path(r'C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd')
B=Path(r'C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B')
RUN=ROOT/'.visio-runs'/'ethernet_video_architecture'
RUN.mkdir(parents=True,exist_ok=True)
OUTPUT=ROOT/'以太网视频传输与接收显示架构图.vsdx'
if OUTPUT.exists():
    raise FileExistsError(OUTPUT)

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    obj=importlib.util.module_from_spec(spec)
    sys.modules[name]=obj
    spec.loader.exec_module(obj)
    return obj

sys.path.insert(0,str(SKILL/'scripts'))
engine=load('eth_visio_engine',SKILL/'scripts'/'New-VisioDiagram.py')
rtl_parser=load('eth_rtl_parser',SKILL/'scripts'/'verilog_to_visio.py')
rtl_sources=[A/'td_project/import'/n for n in ['ethernet_video_tx_top.v','video_udp_tx.v',
    'ethernet_video_sampler.v','video_udp_async_fifo.v']]
rtl_sources += [B/'td_project/import'/n for n in ['ethernet_video_rx_top.v','video_udp_rx.v',
    'ethernet_video_ddr_framebuffer.v','ethernet_video_ddr_mux.v']]
rtl_sources += [A/'td_project/ethernet/uiudp_stack'/n for n in ['uiudp_stack.v','rgmii_interface.v']]
modules=rtl_parser.parse_modules(rtl_sources)
auto={t:rtl_parser.build_spec(modules[t],modules) for t in ['ethernet_video_tx_top','ethernet_video_rx_top']}
(RUN/'rtl-automatic.json').write_text(json.dumps(auto,ensure_ascii=False,indent=2),encoding='utf-8')
sources=rtl_sources+[A/'user_source/hdl_source/design_top_wrapper.v',
    B/'firmware/linux_wifi/lidar_hdmi/rtl/design_top_wrapper.v',
    A/'td_project/camera_to_dsi_display.al',B/'td_project/camera_to_dsi_display_lidar.al']

BLUE,ORANGE,WHITE,INK='#CBE5FE','#FFCB99','#FFFFFF','#202020'
page={'name':'以太网视频传输与显示','nodes':[],'labels':[],'connections':[]}
plan={'page':{'name':page['name'],'width':28,'height':19.15},'shapes':[],'connectors':[]}

def box(sid,x,y,w,h,text='',fill=ORANGE,size=15,container=False):
    page['nodes'].append(dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,shape='roundrect',
        fill=fill,line=INK,fontName='Microsoft YaHei',fontSize=size,container=container))
    plan['shapes'].append(dict(id=sid,x=x,y=y,width=w,height=h,text=text,kind='rectangle',
        shapeIntent='container' if container else 'module'))

def label(sid,x,y,w,h,text,size=14):
    page['labels'].append(dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,
        fontName='Microsoft YaHei',fontSize=size))
    plan['shapes'].append(dict(id=sid,x=x,y=y,width=w,height=h,text=text,kind='text'))

def edge(sid,a,b,fp=(1,.5),tp=(0,.5),both=False,dashed=False,corners=()):
    lookup={s['id']:s for s in plan['shapes']}
    def p(s,port):
        return [s['x']+(port[0]-.5)*s['width'],s['y']+(port[1]-.5)*s['height']]
    points=p(lookup[a],fp)+[v for xy in corners for v in xy]+p(lookup[b],tp)
    c=dict(id=sid,**{'from':a,'to':b},fromX=fp[0],fromY=fp[1],toX=tp[0],toY=tp[1],
        line=INK,lineWeight=.7,endArrow=4,beginArrow=4 if both else 0,
        dashed=dashed,text='',kind='dynamic',points=points)
    page['connections'].append(c)
    plan['connectors'].append(copy.deepcopy(c))

box('a_region',14,14.35,26.3,5.7,fill=BLUE,container=True)
box('b_region',14,5.675,26.3,9.65,fill=BLUE,container=True)
label('title',14,18,26,.6,'以太网视频传输与接收显示架构图',28)
label('a_heading',7,16.65,12,.45,'① A 板：视频采样与发送',22)
label('b_heading',17,10,17,.45,'② B 板：接收重组、DDR 缓存与 HDMI 显示',22)

box('a_video',3.6,13.8,4.2,1.9,'摄像头 / ISP / 视频 DDR\n1280 × 720 RGB888\nOSD 前干净视频',WHITE)
box('a_sampler',8.8,13.8,4.2,1.9,'视频采样与限帧\n2 × 2 采样 → 640 × 360\n最高 30 帧 / 秒\nethernet_video_sampler')
box('a_cdc',14,13.8,4.2,1.9,'格式转换与跨时钟\nRGB888 → RGB565\n像素域 75 → UDP 域125 MHz\nvideo_udp_async_fifo',size=14)
box('a_packet',19.2,13.8,4.2,1.9,'UDP 视频分包 · v3\n每帧 360 包；每包一行\n24 B 包头 + 1280 B 图像\nvideo_udp_tx',size=14.5)
box('a_stack',24.4,13.8,4.2,1.9,'UDP / IP / MAC / PHY\nuiudp_stack\nRGMII / 千兆以太网 PHY\nethernet_video_tx_top',size=14)
box('npu_meta',19.2,15.75,9.4,.9,
    'NPU 结果原子快照与 CDC（160 × 120 推理）\n人员框 / 来源帧号 / 结果 ID → 帧元数据',size=13.5)
label('a_note',11.5,11.9,20,.35,
    '采样与 NPU 输入独立；像素 / 帧标记进入异步 FIFO，128 位元数据保持帧级快照。',14)
label('cable_label',14,11.2,18,.35,
    '千兆以太网 / UDP：192.168.137.2:6002 → 192.168.137.1:6001',15)

box('b_stack',3.6,7.9,4.2,2.1,'PHY / RGMII / 协议解析\nMAC → IP → UDP 载荷\nuiudp_stack\nethernet_video_rx_top',size=14)
box('b_parser',8.8,7.9,4.2,2.1,'视频包检查与像素重组\n版本 / 长度 / 帧号 / 包序\nRGB565 → RGB888 / CDC\nvideo_udp_rx',size=14.5)
box('b_fb',14,7.9,4.2,2.1,'网络帧缓存与显示读出\n完整帧提交；元数据随帧缓存\n行 × 2、像素 × 2 重复\nethernet_video_ddr_framebuffer',size=13.5)
box('b_select',19.2,7.9,4.2,2.1,'本地 / 网络显示源选择\nSW2/B4：高本地 / 低网络\n20 ms 去抖；帧消隐切换\n无有效网络帧时显示黑屏',size=14)
box('b_hdmi',24.4,7.9,4.2,2.1,'OSD / 云图 / HDMI\n人员框、Logo、FPS与传感器\nHDMI：1280 × 720\n像素时钟：75 MHz',WHITE,size=14)
box('b_bad',3.6,4.3,4.2,2.3,'接收异常处理\n长度 / 版本 / 包序检查\n丢包 / 乱序 / FIFO 溢出\n终止当前帧，等待下一帧',WHITE,size=14)
box('b_ddr',13.7,4.3,9.6,2.3,
    '共享 DDR 视频分区\n本地 / 网络请求合并：ethernet_video_ddr_mux\n视频 / CPU 仲裁：ddr_video_cpu_arbiter\n网络双缓冲：0x01000000 / 0x01080000（字节地址）\n2 × 512 KiB 槽；与 CPU / Linux DDR 分区隔离',size=14)
box('b_local',24.4,4.3,4.2,2.3,
    'B 板本地视频输入\n摄像头 / ISP / DDR\n本地图像处理与 HSV\n作为本地显示输入',WHITE,size=14.5)
label('metadata_label',18.5,9.55,10.5,.25,'帧元数据解码：人员框 / 来源帧号 / 结果 ID',13)
label('format_note',14,2.05,25,.7,
    '传输：640 × 360 RGB565；显示：1280 × 720（2 × 2 重复扩展）\nUDP v3：360 包 / 帧；每包 1304 B 应用载荷 = 24 B 视频包头 + 1280 B 图像',14)
label('basis',14,1.2,25,.3,'依据当前 A 板发送端与 B 板 work_B 接收显示端 RTL 整理；实线为主数据路径，虚线为结果 / 异常信息。',12)

for a,b in [('a_video','a_sampler'),('a_sampler','a_cdc'),('a_cdc','a_packet'),('a_packet','a_stack')]:
    edge(a+'_to_'+b,a,b)
edge('metadata_to_packet','npu_meta','a_packet',(.5,0),(.5,1),dashed=True)
edge('ethernet_link','a_stack','b_stack',(.5,0),(.5,1),corners=[(24.4,10.95),(3.6,10.95)])
for a,b in [('b_stack','b_parser'),('b_parser','b_fb'),('b_fb','b_select'),('b_select','b_hdmi')]:
    edge(a+'_to_'+b,a,b)
edge('metadata_to_osd','b_parser','b_hdmi',(.5,1),(.5,1),dashed=True,
    corners=[(8.8,9.2),(24.4,9.2)])
edge('framebuffer_ddr','b_fb','b_ddr',(.5,0),((14-8.9)/9.6,1),both=True)
edge('bad_frame','b_parser','b_bad',(.5,0),(.5,1),dashed=True,corners=[(8.8,6.1),(3.6,6.1)])
edge('local_to_select','b_local','b_select',(0,.5),(.5,0),corners=[(19.2,4.3)])

SPEC={'title':'以太网视频传输与接收显示架构图','pageWidth':28,'pageHeight':19.15,'pages':[page]}
SPEC_PATH=ROOT/'以太网视频传输与接收显示架构图.json'
SPEC_PATH.write_text(json.dumps(SPEC,ensure_ascii=False,indent=2),encoding='utf-8')
(RUN/'layout-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
layout=load('eth_layout_check',Path(r'C:\Users\lx292\.codex\skills\visio-template-drawing\scripts\validate_plan_layout.py'))
findings=layout.validate_page(plan)
if findings:
    raise RuntimeError(json.dumps(findings,ensure_ascii=False,indent=2))

report={'output':str(OUTPUT),'spec':str(SPEC_PATH),'skill':str(SKILL/'SKILL.md'),
    'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    'preflight_findings':findings,'status':'started','hardware_builds_performed':False}
pythoncom.CoInitialize()
app=doc=vpage=shape=connector=window=candidate=None
objects={}
kept=False
try:
    app=win32com.client.DispatchEx('Visio.Application')
    app.Visible=False;app.EventsEnabled=False;app.AlertResponse=2
    report['owned_pid']=win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]
    doc=app.Documents.Add('');vpage=doc.Pages.Item(1);vpage.Name=page['name']
    vpage.PageSheet.CellsU('PageWidth').ResultIU=28
    vpage.PageSheet.CellsU('PageHeight').ResultIU=19.15
    for n in page['nodes']:
        shape=engine.add_node(vpage,n,{})
        shape.NameU=n['id']
        for k,v in {'Rounding':'0.08 in','LineWeight':'0.65 pt',
                    'Char.Color':'RGB(0,0,0)','Char.Style':'0',
                    'Char.AsianFont':'FONT("Microsoft YaHei")'}.items():
            shape.CellsU(k).FormulaU=v
        objects[n['id']]=shape
    for c in page['connections']:
        engine.add_connection(app,vpage,objects,c)
        connector=vpage.Shapes.Item(vpage.Shapes.Count);connector.NameU=c['id']
        connector.CellsU('BeginX').GlueToPos(objects[c['from']],c['fromX'],c['fromY'])
        connector.CellsU('EndX').GlueToPos(objects[c['to']],c['toX'],c['toY'])
        connector.CellsU('EndArrowSize').FormulaU='0';connector.CellsU('BeginArrowSize').FormulaU='0'
        if c['dashed']:connector.CellsU('LinePattern').FormulaU='2'
        connector=None
    for l in page['labels']:
        shape=engine.add_label(vpage,l);shape.NameU=l['id']
        for k,v in {'FillPattern':'0','LinePattern':'0','Char.Color':'RGB(0,0,0)',
                    'Char.AsianFont':'FONT("Microsoft YaHei")'}.items():
            shape.CellsU(k).FormulaU=v
        objects[l['id']]=shape
    assert doc.Pages.Count==1 and vpage.Connects.Count==2*len(page['connections'])
    for row in page['nodes']+page['labels']:
        assert objects[row['id']].Text.rstrip('\r\n')==row['text'].rstrip('\r\n')
    for i in range(1,app.Windows.Count+1):
        candidate=app.Windows.Item(i)
        if candidate.Type==1 and candidate.Document.ID==doc.ID:
            window=candidate;break
    if window is None:raise RuntimeError('Drawing window not found')
    window.ShowGrid=False;window.ShowPageBreaks=False;window.ShowGuides=False;window.ViewFit=1
    doc.SaveAs(str(OUTPUT))
    assert doc.Saved and OUTPUT.stat().st_size>0
    with zipfile.ZipFile(OUTPUT) as z:
        assert z.testzip() is None and not any(n.startswith('visio/media/') for n in z.namelist())
    preview=RUN/'preview.png'
    app.Settings.SetRasterExportResolution(0,90,90,0);vpage.Export(str(preview))
    report.update(status='complete',pages=doc.Pages.Count,native_shapes=vpage.Shapes.Count,
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
        if doc is not None:doc.Saved=True;doc.Close()
        if app is not None:app.Quit()
    objects.clear();shape=connector=candidate=window=vpage=doc=app=None
    gc.collect();pythoncom.CoUninitialize()
print(json.dumps({k:v for k,v in report.items() if k!='source_hashes'},ensure_ascii=False,indent=2))
