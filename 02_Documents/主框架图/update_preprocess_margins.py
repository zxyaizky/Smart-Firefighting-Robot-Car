"""Hide Visio's background page-break lines and add native page margins."""
from pathlib import Path
import math
import zipfile
import win32com.client

OUT=Path(__file__).resolve().parent
app=win32com.client.GetActiveObject('Visio.Application')
doc=app.ActiveDocument
assert doc.Name=='NPU预处理架构图_蓝橙配色.vsdx',doc.Name
p=doc.Pages.Item(1)
shapes=list(p.Shapes)


def appearance(s):
    return (s.Text,tuple(round(s.CellsU(k).ResultIU,8) for k in
            ['Width','Height','Angle','FillForegnd','FillPattern','LineColor','LinePattern']))


before={s.NameU:appearance(s) for s in shapes}
corners=[]
for s in shapes:
    x,y,w,h,lx,ly,a=[s.CellsU(k).ResultIU for k in
                    ['PinX','PinY','Width','Height','LocPinX','LocPinY','Angle']]
    for u,v in [(0,0),(w,0),(0,h),(w,h)]:
        corners.append((x+(u-lx)*math.cos(a)-(v-ly)*math.sin(a),
                        y+(u-lx)*math.sin(a)+(v-ly)*math.cos(a)))
left=min(x for x,y in corners)
right=max(x for x,y in corners)
bottom=min(y for x,y in corners)
top=max(y for x,y in corners)
margin=.8
width,height=right-left+2*margin,top-bottom+2*margin
dx,dy=margin-left,margin-bottom
for s in shapes:
    s.CellsU('PinX').FormulaU=f'{s.CellsU("PinX").ResultIU+dx:.10f} in'
    s.CellsU('PinY').FormulaU=f'{s.CellsU("PinY").ResultIU+dy:.10f} in'
assert {s.NameU:appearance(s) for s in shapes}==before
p.PageSheet.CellsU('PageWidth').FormulaU=f'{width:.10f} in'
p.PageSheet.CellsU('PageHeight').FormulaU=f'{height:.10f} in'
# Native white background keeps the margins in both raster and vector exports.
bg=p.DrawRectangle(0,0,width,height)
bg.NameU='page_white_background'
bg.CellsU('FillForegnd').FormulaU='RGB(255,255,255)'
bg.CellsU('FillPattern').FormulaU='1'
bg.CellsU('LinePattern').FormulaU='0'
bg.SendToBack()
app.ActiveWindow.ShowGrid=False
app.ActiveWindow.ShowPageBreaks=False
assert not app.ActiveWindow.ShowGrid and not app.ActiveWindow.ShowPageBreaks
target=OUT/'NPU预处理架构图_蓝橙配色_留白版.vsdx'
doc.SaveAs(str(target))
app.Settings.SetRasterExportResolution(0,135,135,0)
for ext in ['.png','.svg']:
    p.Export(str(target.with_suffix(ext)))
with zipfile.ZipFile(target) as z:
    assert z.testzip() is None
app.ActiveWindow.ViewFit=1
print(f'PASS: page breaks/grid hidden; {len(shapes)} existing shapes preserved; 0.8 inch margins')
