"""Concise blue-and-white design flow, preserving the code's three core paths."""
from pathlib import Path
import ast
import zipfile
import win32com.client

OUT=Path(__file__).resolve().parent
W,H=14,13.6
C={'navy':'RGB(24,58,103)','blue':'RGB(39,105,179)',
   'light':'RGB(234,243,253)','panel':'RGB(246,249,254)',
   'border':'RGB(183,207,234)','ink':'RGB(34,58,86)',
   'muted':'RGB(94,119,147)','white':'RGB(255,255,255)'}
app=win32com.client.GetActiveObject('Visio.Application')
doc=app.Documents.Add('')
page=doc.Pages.Item(1)
page.Name='简洁设计流程图'
for k,v in [('PageWidth',W),('PageHeight',H),('DrawingScale',1),('PageScale',1)]:
    page.PageSheet.CellsU(k).FormulaU=f'{v} in'
nodes,lines,panels={},[],[]
helper=OUT/'draw_blue_design_flow.py'
tree=ast.parse(helper.read_text(encoding='utf-8'))
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)],
                        type_ignores=[]),str(helper),'exec'))
label('title',7,12.98,13,.6,'双 FPGA 救援车设计流程',27,'navy',True)
shape('requirements',7,11.85,10,.83,'需求分析与双 FPGA 架构划分',
      fill='navy',stroke=None,size=20,color='white',bold=True)
shape('platform',7,10.5,10,.83,'硬件平台与基础接口搭建',fill='light',size=20,bold=True,color='navy')
arrow('start_platform',[(7,11.435),(7,10.915)])
branches=[(2.55,'A 板','NPU 人员识别'),(7,'B 板','HSV 识别与救援控制'),
          (11.45,'RISC-V / Linux','Flash → DDR 启动与通信')]
for i,(x,title,detail) in enumerate(branches):
    card('branch_'+str(i),x,8.55,3.95,title,detail,h=1.25)
    arrow('split_'+str(i),[(7,10.085),(7,9.65),(x,9.65),(x,9.175)])
    if i!=1:
        s=page.DrawPolyline([x,7.925,x,7.35,7,7.35],0)
        s.NameU='merge_side_'+str(i)
        for k,v in {'LineColor':C['blue'],'LineWeight':'1.5 pt','FillPattern':0}.items():
            setc(s,k,v)
        s.SendToBack()
    else:
        arrow('merge_center',[(7,7.925),(7,6.965)])
for key,y,title in [
    ('integration',6.55,'跨板通信与显示 / 控制集成'),
    ('verification',5.05,'RTL 仿真 → 综合 → 布局布线'),
    ('deployment',3.55,'Flash 镜像合成与 FPGA 上板调试'),
    ('finish',2.05,'整机联调与性能优化')]:
    shape(key,7,y,10,.83,title,fill='navy' if key=='finish' else 'light',
          stroke=None if key=='finish' else 'border',size=20,
          color='white' if key=='finish' else 'navy',bold=True)
    if key!='integration':
        arrow('next_'+key,[(7,y+1.5-.415),(7,y+.415)])
arrow('retry',[(12,5.05),(13.55,5.05),(13.55,6.55),(12,6.55)],True)
label('retry_label',12.8,5.8,1.4,.5,'未通过\n返回优化',11,'blue')
assert len(branches)==3
base=OUT/'双FPGA救援车_蓝白设计流程图_简洁版'
doc.SaveAs(str(base.with_suffix('.vsdx')))
app.Settings.SetRasterExportResolution(0,130,130,0)
for suffix in ['.png','.svg']:
    page.Export(str(base.with_suffix(suffix)))
with zipfile.ZipFile(base.with_suffix('.vsdx')) as z:
    assert z.testzip() is None
    xml=z.read('visio/pages/page1.xml').decode('utf-8')
    assert all(token in xml for token in ['Flash','NPU','HSV','整机联调'])
app.Visible=True
app.ActiveWindow.ViewFit=1
print('PASS: concise native Visio flow saved; 9 process nodes')
