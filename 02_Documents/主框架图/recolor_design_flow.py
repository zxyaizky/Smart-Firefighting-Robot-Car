"""Apply the user's sampled light-blue / peach palette without changing layout."""
from pathlib import Path
import json
import zipfile
import win32com.client

OUT=Path(__file__).resolve().parent
SOURCE=OUT/'双FPGA救援车_蓝白设计流程图_适中版.vsdx'
TARGET=OUT/'双FPGA救援车_设计流程图_蓝橙配色.vsdx'
BLUE='RGB(203,229,254)'
ORANGE='RGB(255,203,153)'
INK='RGB(0,0,0)'
app=win32com.client.GetActiveObject('Visio.Application')
doc=next((d for d in app.Documents if d.Type==1 and Path(d.FullName)==SOURCE),None)
if doc is None:
    doc=app.Documents.Open(str(SOURCE))
page=doc.Pages.Item(1)


def snapshot():
    return {s.NameU:(s.Text,tuple(round(s.CellsU(k).ResultIU,8)
            for k in ['PinX','PinY','Width','Height','Angle'])) for s in page.Shapes}


before=snapshot()
doc.SaveAs(str(TARGET))
for s in page.Shapes:
    name=s.NameU
    filled=int(s.CellsU('FillPattern').ResultIU)!=0
    if filled:
        color=BLUE if name.startswith(('panel_','branch_header_')) or name=='check' else ORANGE
        if name.endswith('_accent'):
            color='RGB(234,164,100)'
        s.CellsU('FillForegnd').FormulaU=color
    if int(s.CellsU('LinePattern').ResultIU)!=0:
        s.CellsU('LineColor').FormulaU=INK
    if s.Text:
        for i in range(s.RowCount(3)):
            s.CellsSRC(3,i,1).FormulaU=INK  # Character.Color for every text run.
        s.CellsU('Char.Color').FormulaU=INK
assert snapshot()==before,'Only colors may change'
doc.Save()
app.Settings.SetRasterExportResolution(0,130,130,0)
for ext in ['.png','.svg']:
    page.Export(str(TARGET.with_suffix(ext)))
with zipfile.ZipFile(TARGET) as z:
    assert z.testzip() is None
(OUT/'蓝橙配色_核对.json').write_text(json.dumps({
    'source':str(SOURCE),'output':str(TARGET),
    'sampled_reference_palette':{'light_blue':[203,229,254],'peach':[255,203,153]},
    'shape_count':page.Shapes.Count,'content_and_geometry_unchanged':True,
    'vsdx_package_check':'PASS'},ensure_ascii=False,indent=2),encoding='utf-8')
app.Visible=True
app.ActiveWindow.ViewFit=1
print('PASS: palette updated; all text and geometry unchanged')
