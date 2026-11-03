"""Draw the user's twelve-stage development flow as native Visio objects."""
from pathlib import Path
import ast
import zipfile
import win32com.client

OUT = Path(__file__).resolve().parent
W, H = 11, 22
GREEN = 'RGB(146,208,80)'
STEPS = [
    '需求分析',
    '双FPGA系统架构设计',
    '硬件平台搭建',
    '图像采集与处理',
    '轻量化NPU设计',
    'YOLO人物识别与火焰检测部署',
    'RISC-V CPU协同及通信设计',
    '视觉引导的小车运动与机械臂控制',
    '自动灭火系统开发',
    'RTL仿真与综合',
    'FPGA上板调试',
    '整机联调与性能优化',
]

app = win32com.client.GetActiveObject('Visio.Application')
doc = app.Documents.Add('')
page = doc.Pages.Item(1)
page.Name = '系统开发流程图'
for key, value in [('PageWidth',W),('PageHeight',H),('DrawingScale',1),('PageScale',1)]:
    page.PageSheet.CellsU(key).FormulaU = f'{value} in'
blocks, edges = {}, []
helper = OUT/'draw_reference_style.py'
tree = ast.parse(helper.read_text(encoding='utf-8'))
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)],
                        type_ignores=[]),str(helper),'exec'))
text('title',5.5,21.15,10,.65,'双FPGA救援车系统开发流程图',28,bold=True)
for i, step in enumerate(STEPS):
    y = 19.8 - i*1.65
    rect(f'stage_{i+1:02}',5.5,y,8.7,1.05,step,green=True,size=22)
    if i:
        line(f'next_{i:02}',[(5.5,y+1.65-.525),(5.5,y+.525)])

assert len(STEPS)==12 and len(edges)==11
assert [blocks[f'stage_{i+1:02}']['shape'].Text for i in range(12)] == STEPS
base = OUT/'双FPGA救援车_系统开发流程图'
doc.SaveAs(str(base.with_suffix('.vsdx')))
app.Settings.SetRasterExportResolution(0,120,120,0)
for suffix in ('.png','.svg'):
    page.Export(str(base.with_suffix(suffix)))
with zipfile.ZipFile(base.with_suffix('.vsdx')) as package:
    assert package.testzip() is None
    xml=package.read('visio/pages/page1.xml').decode('utf-8')
    assert all(step in xml for step in STEPS)
app.Visible=True
app.ActiveWindow.ViewFit=1
print(f'PASS: 12 stages, 11 arrows; {base.with_suffix(".vsdx")}')
