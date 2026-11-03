"""Restyle the same design flow to match the supplied restrained NPU diagram."""
from pathlib import Path
import gc
import hashlib
import json
import traceback
import zipfile

import pythoncom
import win32com.client
import win32process

ROOT=Path(__file__).parent
SOURCE=ROOT/'双FPGA救援车设计流程_蓝橙配色_留白版.vsdx'
OUTPUT=ROOT/'双FPGA救援车设计流程_参考NPU风格.vsdx'
RUN=ROOT/'.visio-runs'/'flow_npu_reference_style'
RUN.mkdir(parents=True,exist_ok=True)
if OUTPUT.exists():
    raise FileExistsError(OUTPUT)
SOURCE_HASH=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
report={'source':str(SOURCE),'output':str(OUTPUT),'status':'started',
        'style':'pale blue regions, peach modules, white boundary nodes, thin black lines, regular text'}
pythoncom.CoInitialize()
app=doc=page=shape=window=candidate=None
kept=False
try:
    app=win32com.client.DispatchEx('Visio.Application')
    app.Visible=False
    app.EventsEnabled=False
    app.AlertResponse=2
    report['owned_pid']=win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]
    doc=app.Documents.OpenEx(str(SOURCE),1+128+256+8)
    assert doc.Pages.Count==1
    page=doc.Pages.Item(1)
    page.Name='设计流程_参考NPU风格'
    original={}
    for i in range(1,page.Shapes.Count+1):
        shape=page.Shapes.Item(i)
        original[shape.NameU]=shape.Text
    removed=[]
    for i in range(page.Shapes.Count,0,-1):
        shape=page.Shapes.Item(i)
        if shape.NameU.endswith('_accent'):
            removed.append(shape.NameU)
            shape.Delete()
    for i in range(1,page.Shapes.Count+1):
        shape=page.Shapes.Item(i)
        name=shape.NameU
        shape.CellsU('Char.Font').FormulaU='FONT("Microsoft YaHei")'
        shape.CellsU('Char.AsianFont').FormulaU='FONT("Microsoft YaHei")'
        shape.CellsU('Char.Color').FormulaU='RGB(0,0,0)'
        shape.CellsU('Char.Style').FormulaU='0'
        shape.CellsU('LineColor').FormulaU='RGB(32,32,32)'
        shape.CellsU('LineWeight').FormulaU='0.65 pt'
        if name.startswith('panel_'):
            shape.CellsU('FillForegnd').FormulaU='RGB(203,229,254)'
            shape.CellsU('Rounding').FormulaU='0.07 in'
        elif name.startswith('branch_header_'):
            shape.CellsU('FillPattern').FormulaU='0'
            shape.CellsU('LinePattern').FormulaU='0'
            shape.CellsU('Char.Size').FormulaU='17 pt'
        elif name=='title':
            shape.CellsU('Char.Size').FormulaU='24 pt'
        elif name in ['requirements','finish','check']:
            shape.CellsU('FillForegnd').FormulaU='RGB(255,255,255)'
            shape.CellsU('Char.Size').FormulaU='15 pt' if name=='check' else '18 pt'
        elif name=='platform':
            shape.CellsU('Char.Size').FormulaU='18 pt'
        elif name.endswith('_title'):
            shape.CellsU('Char.Size').FormulaU='16 pt'
        elif name.endswith('_detail'):
            shape.CellsU('Char.Size').FormulaU='13 pt'
        elif name=='retry_label':
            shape.CellsU('Char.Size').FormulaU='12 pt'
        elif name=='yes':
            shape.CellsU('Char.Size').FormulaU='12 pt'
        if shape.CellsU('EndArrow').ResultIU:
            shape.CellsU('EndArrow').FormulaU='4'
            shape.CellsU('EndArrowSize').FormulaU='0'
        assert shape.Text==original[name]
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
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()==SOURCE_HASH
    with zipfile.ZipFile(OUTPUT) as z:
        assert z.testzip() is None
        assert not any(n.startswith('visio/media/') for n in z.namelist())
    preview=RUN/'preview.png'
    app.Settings.SetRasterExportResolution(0,90,90,0)
    page.Export(str(preview))
    report.update(status='complete',native_shapes=page.Shapes.Count,removed_decoration=removed,
        text_preserved=True,source_unchanged=True,grid=bool(window.ShowGrid),
        page_breaks=bool(window.ShowPageBreaks),page_margins_inches=.85,
        preview=str(preview),pages=doc.Pages.Count)
    app.EventsEnabled=True
    app.AlertResponse=0
    app.Visible=True
    window.Activate()
    window.ViewFit=1
    kept=True
    report['final_window_retained']=True
except Exception:
    report.update(status='failed',error=traceback.format_exc())
    raise
finally:
    (RUN/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    if not kept:
        if doc is not None:
            doc.Saved=True
            doc.Close()
        if app is not None:
            app.Quit()
    shape=candidate=window=page=doc=app=None
    gc.collect()
    pythoncom.CoUninitialize()
print(json.dumps(report,ensure_ascii=False,indent=2))
