"""Redraw the supplied NPU reference in one visible Visio page, with margins."""
from pathlib import Path

OUT=Path(__file__).resolve().parent
original=OUT/'draw_npu_architecture.py'
source=original.read_text(encoding='utf-8')
source=source.replace("base=OUT/'NPU总体架构图_蓝橙配色'",
                      "base=OUT/'NPU总体架构图_蓝橙配色_重绘留白版'")
source=source.replace("'NPU总体架构图_来源核对.json'",
                      "'NPU总体架构图_重绘留白版_来源核对.json'")
margin_code='''
# Keep original text, native geometry and colors; translate the drawing only.
import math
existing=list(page.Shapes)
before={s.NameU:(s.Text,s.CellsU('Width').ResultIU,s.CellsU('Height').ResultIU)
        for s in existing}
corners=[]
for s in existing:
    px,py,w,h,lx,ly,a=[s.CellsU(k).ResultIU for k in
                       ['PinX','PinY','Width','Height','LocPinX','LocPinY','Angle']]
    for u,v in [(0,0),(w,0),(0,h),(w,h)]:
        corners.append((px+(u-lx)*math.cos(a)-(v-ly)*math.sin(a),
                        py+(u-lx)*math.sin(a)+(v-ly)*math.cos(a)))
left=min(x for x,y in corners);right=max(x for x,y in corners)
bottom=min(y for x,y in corners);top=max(y for x,y in corners)
margin=.8
dx,dy=margin-left,margin-bottom
for s in existing:
    s.CellsU('PinX').FormulaU=f'{s.CellsU("PinX").ResultIU+dx:.10f} in'
    s.CellsU('PinY').FormulaU=f'{s.CellsU("PinY").ResultIU+dy:.10f} in'
assert all(s.Text==before[s.NameU][0] and
           abs(s.CellsU('Width').ResultIU-before[s.NameU][1])<1e-8 and
           abs(s.CellsU('Height').ResultIU-before[s.NameU][2])<1e-8 for s in existing)
pw,ph=right-left+2*margin,top-bottom+2*margin
page.PageSheet.CellsU('PageWidth').FormulaU=f'{pw:.10f} in'
page.PageSheet.CellsU('PageHeight').FormulaU=f'{ph:.10f} in'
bg=page.DrawRectangle(0,0,pw,ph)
bg.NameU='page_white_background'
bg.CellsU('FillPattern').FormulaU='1'
bg.CellsU('FillForegnd').FormulaU='RGB(255,255,255)'
bg.CellsU('LinePattern').FormulaU='0'
bg.SendToBack()
app.Visible=True
app.ActiveWindow.Page=page
app.ActiveWindow.ShowGrid=False
app.ActiveWindow.ShowPageBreaks=False
assert doc.Pages.Count==1 and app.ActiveDocument==doc
assert app.ActiveWindow.Page.Name==page.Name
doc.SaveAs(str(base.with_suffix('.vsdx')))
'''
assert source.count("doc.SaveAs(str(base.with_suffix('.vsdx')))")==1
source=source.replace("doc.SaveAs(str(base.with_suffix('.vsdx')))",margin_code)
exec(compile(source,str(original),'exec'),{'__file__':str(original),'__name__':'__main__'})
