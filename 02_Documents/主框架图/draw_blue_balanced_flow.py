"""Moderately detailed blue-and-white Visio design workflow."""
from pathlib import Path
import ast
import zipfile
import win32com.client

OUT=Path(__file__).resolve().parent
W,H=16,17.2
C={'navy':'RGB(24,58,103)','blue':'RGB(39,105,179)',
   'light':'RGB(234,243,253)','panel':'RGB(246,249,254)',
   'border':'RGB(183,207,234)','ink':'RGB(34,58,86)',
   'muted':'RGB(94,119,147)','white':'RGB(255,255,255)'}
app=win32com.client.GetActiveObject('Visio.Application')
doc=app.Documents.Add('')
page=doc.Pages.Item(1)
page.Name='设计流程图_适中版'
for k,v in [('PageWidth',W),('PageHeight',H),('DrawingScale',1),('PageScale',1)]:
    page.PageSheet.CellsU(k).FormulaU=f'{v} in'
nodes,lines,panels={},[],[]
helper=OUT/'draw_blue_design_flow.py'
tree=ast.parse(helper.read_text(encoding='utf-8'))
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)],
                        type_ignores=[]),str(helper),'exec'))


def bus(key,points):
    s=page.DrawPolyline([v for p in points for v in p],0)
    s.NameU=key
    for k,v in {'LineColor':C['blue'],'LineWeight':'1.5 pt','FillPattern':0}.items():
        setc(s,k,v)
    s.SendToBack()


label('title',8,16.55,15,.6,'双 FPGA 救援车设计流程',28,'navy',True)
shape('requirements',8,15.4,12.2,.86,'需求分析与双 FPGA 架构设计',
      fill='navy',stroke=None,size=21,color='white',bold=True)
shape('platform',8,14.0,12.2,.86,'硬件平台搭建与基础接口配置',
      fill='light',size=20,color='navy',bold=True)
arrow('requirements_platform',[(8,14.97),(8,14.43)])
bus('split_bus',[(3,12.85),(3,13.15),(13,13.15),(13,12.85)])
bus('split_trunk',[(8,13.57),(8,12.85)])
branches=[
    (3,'A 板 · 视频与推理',[
        ('图像采集与预处理','MIPI / ISP / DDR 图像缓存'),
        ('NPU 人员识别与视频发送','轻量化推理 / UDP 视频与人员框')]),
    (8,'B 板 · 感知与控制',[
        ('黄绿目标识别与测距','HSV 火焰 / 物资识别、超声波测距'),
        ('小车与执行机构控制','小车运动 / 机械臂 / 瞄准喷水')]),
    (13,'RISC-V · Linux 与通信',[
        ('Flash 启动与 Linux 部署','U33 Flash → DDR；VexRiscv 启动'),
        ('无线通信与云图生成','ESP32 / PPP / SSH、地图 MMIO')])]
for i,(x,title,steps) in enumerate(branches):
    panels.append(shape('panel_'+str(i),x,11.05,4.65,4.18,fill='panel'))
    shape('branch_header_'+str(i),x,12.55,4.45,.6,title,
          fill='blue',stroke=None,size=16,bold=True,color='white')
    for j,(title,detail) in enumerate(steps):
        y=11.4-j*1.65
        card(f'branch_{i}_{j}',x,y,4.2,title,detail,h=1.14)
        arrow(f'branch_next_{i}_{j}',[(x,12.25 if j==0 else 11.4-.57),(x,y+.57)])
    bus('merge_'+str(i),[(x,9.18),(x,8.72),(8,8.72)])
arrow('merge_integration',[(8,8.72),(8,8.37)])
card('integration',8,7.8,12.2,'跨板通信与系统集成',
     '感知结果汇合，联动显示、运动、抓取、消防和语音',h=1.14,fill='light')
card('verification',8,6.35,12.2,'RTL 仿真与 FPGA 实现',
     '功能仿真 → 综合 → 布局布线；检查资源与时序',h=1.14)
arrow('integration_verify',[(8,7.23),(8,6.92)])
shape('check',8,4.88,4.6,1.1,'功能与时序\n是否满足要求？',
      fill='light',stroke='blue',size=17,bold=True,color='navy',kind='diamond')
arrow('verification_check',[(8,5.78),(8,5.43)])
arrow('retry',[(10.3,4.88),(15.55,4.88),(15.55,7.8),(14.1,7.8)],True)
label('retry_label',12.65,5.2,4.0,.34,'否：修改模块 / 约束后重新验证',12,'blue')
card('deployment',8,3.35,12.2,'Flash 打包与 FPGA 上板调试',
     '合并配置、Linux 与 MCU 镜像，检查启动和实车动作',h=1.14,fill='light')
arrow('check_deployment',[(8,4.33),(8,3.92)])
label('yes',8.45,4.12,.6,.3,'是',12,'blue',True)
shape('finish',8,1.85,12.2,.95,'整机联调与性能优化',fill='navy',stroke=None,
      size=21,bold=True,color='white')
arrow('deployment_finish',[(8,2.78),(8,2.325)])
for p in panels:
    p.SendToBack()
assert len(branches)==3 and all(len(row[2])==2 for row in branches)
assert sum(k in nodes for k in ['requirements','platform','integration','verification','check','deployment','finish'])==7
base=OUT/'双FPGA救援车_蓝白设计流程图_适中版'
doc.SaveAs(str(base.with_suffix('.vsdx')))
app.Settings.SetRasterExportResolution(0,130,130,0)
for suffix in ['.png','.svg']:
    page.Export(str(base.with_suffix(suffix)))
with zipfile.ZipFile(base.with_suffix('.vsdx')) as z:
    assert z.testzip() is None
    xml=z.read('visio/pages/page1.xml').decode('utf-8')
    assert all(t in xml for t in ['U33 Flash','NPU','HSV','整机联调','是否满足要求'])
app.Visible=True
app.ActiveWindow.ViewFit=1
print('PASS: 13 design/decision nodes; editable Visio and PNG/SVG exported')
