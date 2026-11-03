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
SOURCE=ROOT/'双FPGA救援车设计流程_按原图重绘.vsdx'
OUTPUT=ROOT/'双FPGA救援车设计流程_蓝橙配色_留白版.vsdx'
RUN=ROOT/'.visio-runs'/'blue_orange_reference_flow'
RUN.mkdir(parents=True,exist_ok=True)
if OUTPUT.exists():
    raise FileExistsError(OUTPUT)
SOURCE_HASH=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
MODULES={'requirements','platform','integration','verification','deployment','finish','check'}
MODULES.update(f'branch_header_{i}' for i in range(3))
MODULES.update(f'branch_{i}_{j}' for i in range(3) for j in range(2))
BLUE='RGB(203,229,254)'
ORANGE='RGB(255,203,153)'
INK='RGB(32,32,32)'
MARGIN=.85
report={'source':str(SOURCE),'output':str(OUTPUT),'status':'started',
        'palette':{'group':'#CBE5FE','module':'#FFCB99','line':'#202020'},
        'margin_inches':MARGIN}
app=doc=page=shape=window=candidate=None
kept=False
pythoncom.CoInitialize()
try:
    app=win32com.client.DispatchEx('Visio.Application')
    app.Visible=False
    app.EventsEnabled=False
    app.AlertResponse=2
    report['owned_pid']=win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]
    doc=app.Documents.OpenEx(str(SOURCE),1+128+256+8)
    page=doc.Pages.Item(1)
    assert doc.Pages.Count==1
    page.Name='设计流程_蓝橙配色'
    records=[]
    for i in range(1,page.Shapes.Count+1):
        shape=page.Shapes.Item(i)
        records.append({'id':shape.NameU,'text':shape.Text,
            **{k:shape.CellsU(k).ResultIU for k in ['PinX','PinY','Width','Height']}})
    left=min(r['PinX']-abs(r['Width'])/2 for r in records)
    right=max(r['PinX']+abs(r['Width'])/2 for r in records)
    bottom=min(r['PinY']-abs(r['Height'])/2 for r in records)
    top=max(r['PinY']+abs(r['Height'])/2 for r in records)
    dx,dy=MARGIN-left,MARGIN-bottom
    for i,row in enumerate(records,1):
        shape=page.Shapes.Item(i)
        name=row['id']
        shape.CellsU('PinX').FormulaForceU=f"{row['PinX']+dx:.10f} in"
        shape.CellsU('PinY').FormulaForceU=f"{row['PinY']+dy:.10f} in"
        shape.CellsU('Char.Color').FormulaU=INK
        shape.CellsU('LineColor').FormulaU=INK
        if name.startswith('panel_') or name in MODULES:
            shape.CellsU('FillForegnd').FormulaU=BLUE if name.startswith('panel_') else ORANGE
            shape.CellsU('FillPattern').FormulaU='1'
            shape.CellsU('LinePattern').FormulaU='1'
            shape.CellsU('LineWeight').FormulaU='1 pt'
        elif name.endswith('_accent'):
            shape.CellsU('FillForegnd').FormulaU='RGB(91,155,213)'
        assert shape.Text==row['text']
        assert abs(shape.CellsU('Width').ResultIU-row['Width'])<1e-6
        assert abs(shape.CellsU('Height').ResultIU-row['Height'])<1e-6
    width,height=right-left+2*MARGIN,top-bottom+2*MARGIN
    page.PageSheet.CellsU('PageWidth').ResultIU=width
    page.PageSheet.CellsU('PageHeight').ResultIU=height
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
    app.Settings.SetRasterExportResolution(0,100,100,0)
    page.Export(str(preview))
    report.update(status='complete',pages=doc.Pages.Count,native_shapes=page.Shapes.Count,
        text_and_shape_sizes_preserved=True,grid=bool(window.ShowGrid),
        page_breaks=bool(window.ShowPageBreaks),preview=str(preview),
        page_width=width,page_height=height,source_unchanged=True)
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
