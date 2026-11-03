"""Code-grounded design workflow, authored as editable native Visio shapes."""
from pathlib import Path
import hashlib
import json
import zipfile
import win32com.client

OUT = Path(__file__).resolve().parent
ROOT = OUT.parent
W,H = 20,18.6
C = {'navy':'RGB(24,58,103)', 'blue':'RGB(39,105,179)',
     'light':'RGB(234,243,253)', 'panel':'RGB(246,249,254)',
     'border':'RGB(183,207,234)', 'ink':'RGB(34,58,86)',
     'muted':'RGB(94,119,147)', 'white':'RGB(255,255,255)'}
app=win32com.client.GetActiveObject('Visio.Application')
doc=app.Documents.Add('')
page=doc.Pages.Item(1)
page.Name='蓝白设计流程图'
for name,value in [('PageWidth',W),('PageHeight',H),('DrawingScale',1),('PageScale',1)]:
    page.PageSheet.CellsU(name).FormulaU=f'{value} in'
nodes,lines,panels={},[],[]


def setc(s,k,v):
    s.CellsU(k).FormulaU=str(v)


def shape(key,x,y,w,h,content='',fill='white',stroke='border',size=15,bold=False,
          color='ink',kind='rect'):
    assert 0<=x-w/2<x+w/2<=W and 0<=y-h/2<y+h/2<=H
    if kind=='diamond':
        s=page.DrawPolyline([x,y+h/2,x+w/2,y,x,y-h/2,x-w/2,y,x,y+h/2],0)
    elif kind=='circle':
        s=page.DrawOval(x-w/2,y-h/2,x+w/2,y+h/2)
    else:
        s=page.DrawRectangle(x-w/2,y-h/2,x+w/2,y+h/2)
    s.NameU,s.Text=key,content
    for k,v in {'FillPattern':1,'FillForegnd':C[fill],
                'LineColor':C[stroke] if stroke else C[fill],
                'LinePattern':1 if stroke else 0,'LineWeight':'1 pt',
                'Char.Font':'FONT("Microsoft YaHei")',
                'Char.AsianFont':'FONT("Microsoft YaHei")',
                'Char.Size':f'{size} pt','Char.Style':1 if bold else 0,
                'Char.Color':C[color],'Para.HorzAlign':1,'VerticalAlign':1,
                'LeftMargin':'.06 in','RightMargin':'.06 in',
                'TopMargin':'.025 in','BottomMargin':'.025 in'}.items():
        setc(s,k,v)
    if kind=='rect':
        setc(s,'Rounding','.09 in')
    nodes[key]={'shape':s,'text':content,'bounds':[x-w/2,y-h/2,x+w/2,y+h/2]}
    return s


def label(key,x,y,w,h,content,size=13,color='muted',bold=False):
    s=shape(key,x,y,w,h,content,size=size,stroke=None,color=color,bold=bold)
    setc(s,'FillPattern',0)
    return s


def arrow(key,pts,dashed=False):
    assert all(0<=x<=W and 0<=y<=H for x,y in pts)
    s=page.DrawPolyline([v for p in pts for v in p],0)
    s.NameU=key
    for k,v in {'FillPattern':0,'LineColor':C['blue'],'LineWeight':'1.5 pt',
                'LinePattern':2 if dashed else 1,'EndArrow':13,
                'EndArrowSize':2}.items():
        setc(s,k,v)
    s.SendToBack()
    lines.append({'id':key,'points':pts})


def card(key,x,y,w,title,detail,h=1.12,fill='white'):
    s=shape(key,x,y,w,h,fill=fill)
    shape(key+'_accent',x-w/2+.035,y,.07,h-.13,fill='blue',stroke=None)
    label(key+'_title',x,y+.22,w-.25,.36,title,16,'navy',True)
    label(key+'_detail',x,y-.22,w-.25,.43,detail,12,'muted')
    return s


def phase(num,y,title,detail):
    shape('phase_'+num,1.1,y,.54,.54,num,fill='blue',stroke=None,size=14,
          color='white',bold=True,kind='circle')
    label('phase_title_'+num,1.1,y-.57,1.85,.4,title,15,'navy',True)
    label('phase_detail_'+num,1.1,y-1.02,1.85,.45,detail,11)


label('title',10.45,18.0,18,.65,'双 FPGA 救援车 · 系统设计流程',29,'navy',True)
label('subtitle',10.45,17.45,17,.35,'需求与架构  /  三条设计支路  /  系统集成  /  验证与迭代',13)
phase('01',16.55,'需求与架构','明确任务\n划分 A / B 职责')
phase('02',12.8,'模块设计','按代码分工\n并行推进')
phase('03',7.35,'系统集成','汇合感知结果\n联动显示与执行')
phase('04',5.4,'仿真与实现','功能验证\n资源 / 时序检查')
phase('05',2.85,'部署与联调','Flash 启动\n实车标定与优化')

shape('requirements',10.5,16.5,14.8,.82,
      '任务分析与双 FPGA 架构划分：人员识别、物资抓取、火焰消防、医疗与地图显示',
      fill='navy',stroke=None,size=17,bold=True,color='white')
shape('platform',10.5,15.2,14.8,.9,
      '搭建硬件平台与公共接口\n双摄像头 / DDR / 时钟复位 / Ethernet / UART / I²C / PWM',
      fill='light',size=16,bold=True,color='navy')
arrow('requirements_platform',[(10.5,16.09),(10.5,15.65)])

LANES=[
 ('A',5.4,'A 板：视频与 NPU 人员识别',[
     ('摄像头采集与图像预处理','MIPI / RAW10 → ISP → DDR 图像缓存'),
     ('轻量化 NPU 与人员检测部署','160 × 120 输入；Flash 参数装载与 DDR 供权重'),
     ('以太网视频与结果发送','640 × 360 RGB565；UDP 视频 + 人员框 / 帧号')]),
 ('B',10.5,'B 板：本地感知与救援控制',[
     ('本地视频与传感器接入','ISP / DDR；超声波测距、心率 / 血氧采集'),
     ('黄绿目标识别与结果确认','HSV 黄色火焰 / 绿色物资；去噪与目标框'),
     ('视觉引导的任务状态机','小车运动、六关节机械臂、瞄准喷水及语音')]),
 ('CPU',15.6,'RISC-V：Linux 与地图通信',[
     ('VexRiscv 与 Linux 启动设计','U33 Flash → MCU / AHB → ROM Loader → DDR'),
     ('雷达数据与无线通信设计','L150 → 电脑 → Wi-Fi / ESP32 → UART / PPP'),
     ('云图生成与显示接口','Linux 接收点云；地图 MMIO / 双缓冲与近似着色')])]
for key,x,title,cards in LANES:
    panels.append(shape('panel_'+key,x,11.05,4.8,6.1,fill='panel',stroke='border'))
    shape('lane_'+key,x,13.67,4.5,.55,title,fill='blue',stroke=None,
          size=15,bold=True,color='white')
    for i,(title,detail) in enumerate(cards):
        y=12.5-i*1.7
        card(key+'_card_'+str(i),x,y,4.34,title,detail)
        if i:
            arrow(key+'_next_'+str(i),[(x,y+1.7-.56),(x,y+.56)])
    arrow('branch_'+key,[(10.5,14.75),(10.5,14.42),(x,14.42),(x,13.06)])
    arrow('merge_'+key,[(x,8.54),(x,7.95),(10.5,7.95),(10.5,7.81)])

card('integration',10.5,7.25,14.8,'跨板系统集成与显示 / 控制联动',
     '人员 / 黄绿目标 / 距离经 CDC 汇合；B4 视频切换，叠加目标框、距离、血氧和雷达云图',fill='light')
card('verification',10.5,5.83,14.8,'RTL 功能仿真 → 综合 → 布局布线',
     '检查帧与结果一致性、任务状态机、串口 / PWM、资源占用、Setup / Hold 与约束')
arrow('integration_verify',[(10.5,6.69),(10.5,6.39)])
shape('check',10.5,4.42,4.4,1.05,'功能、资源与时序\n是否满足设计要求？',
      fill='light',stroke='blue',size=15,bold=True,color='navy',kind='diamond')
arrow('verify_check',[(10.5,5.27),(10.5,4.945)])
arrow('rtl_retry',[(12.7,4.42),(19.0,4.42),(19.0,7.25),(17.9,7.25)],True)
label('retry_label',16.25,4.72,3.9,.4,'否：定位问题，修改模块与约束',12,'blue',True)
card('program',10.5,2.97,14.8,'生成 bit / 合成 Flash 镜像 → FPGA 上板调试',
     'B 板合并 FPGA 配置、Linux 包和 MCU 固件；上电将 Linux 载入 DDR，检查各接口与实车动作',fill='light')
arrow('check_program',[(10.5,3.895),(10.5,3.53)])
label('yes_label',11.0,3.68,.65,.3,'是',12,'blue',True)
shape('finish',10.5,1.5,14.8,.94,
      '整机联调与性能优化\n标定抓取 / 转向 / 瞄准，评估识别、视频、通信与任务完成情况',
      fill='navy',stroke=None,size=17,color='white',bold=True)
arrow('program_finish',[(10.5,2.41),(10.5,1.97)])
arrow('board_retry',[(17.9,2.97),(18.48,2.97),(18.48,5.83),(17.9,5.83)],True)
label('board_retry_label',18.5,3.5,1.2,.5,'联调问题\n返回验证',10,'blue')
label('footer',10.45,.53,18,.47,
      '依据当前 A / B 工程源码整理。人员识别采用 NPU，黄色火焰 / 绿色物资采用 HSV；图中验证与部署为流程阶段。',11)

for p in panels:
    p.SendToBack()
A=ROOT/'lab_ex3_osd_SC500_720/lab_ex3_osd/user_source/hdl_source/design_top_wrapper.v'
B=ROOT/'test/b_vexriscv_main_20261013/work_B/firmware/linux_wifi/lidar_hdmi'
sources=[A,B/'rtl/design_top_wrapper.v',B/'rtl/rescue/rescue_control.v',
         B/'pack_flash.py',B/'test_rescue.py']
assert all(token in A.read_text(encoding='utf-8-sig') for token in
           ['u_npu_video_input','u_npu_ddr','u_udp_video_input'])
assert all(token in (B/'rtl/design_top_wrapper.v').read_text(encoding='utf-8-sig')
           for token in ['u_rescue_color','u_rescue_control','u_arm_auto','u_fire_spray_burst',
                         'u_vexriscv_linux','u_lidar_map','u_max30102_top'])
assert len(LANES)==3 and all(len(row[3])==3 for row in LANES)
base=OUT/'双FPGA救援车_蓝白设计流程图'
doc.SaveAs(str(base.with_suffix('.vsdx')))
app.Settings.SetRasterExportResolution(0,130,130,0)
for suffix in ['.png','.svg']:
    page.Export(str(base.with_suffix(suffix)))
with zipfile.ZipFile(base.with_suffix('.vsdx')) as z:
    assert z.testzip() is None
    xml=z.read('visio/pages/page1.xml').decode('utf-8')
    assert all(s in xml for s in ['ROM Loader','HSV','功能、资源与时序','整机联调'])
audit={'sources':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
       'shape_count':page.Shapes.Count,'connectors':len(lines),'lanes':3,
       'validation':'PASS: owning code instances, bounds and VSDX structure',
       'meaning':'Design workflow; no claim of completed synthesis or hardware validation'}
(OUT/'蓝白设计流程图_核对.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8')
app.Visible=True
app.ActiveWindow.ViewFit=1
print(json.dumps({'path':str(base.with_suffix('.vsdx')),'shapes':page.Shapes.Count,'check':'PASS'},ensure_ascii=False))
