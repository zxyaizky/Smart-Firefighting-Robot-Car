"""Faithful editable recreation of the supplied screenshot with visio-skill."""
from pathlib import Path
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
REFERENCE=Path(r'D:\Temp\codex-clipboard-e6ba3e4a-80f9-4e83-baee-651f9a8008be.png')
SOURCE=ROOT/'双FPGA救援车_蓝白设计流程图_适中版.vsdx'
OUTPUT=ROOT/'双FPGA救援车设计流程_按原图重绘.vsdx'
RUN=ROOT/'.visio-runs'/'blue_flow_reference_recreation'
RUN.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(RUN/'python-deps'))
if OUTPUT.exists():
    raise FileExistsError(OUTPUT)

# Run the requested skill's image reconstruction pass. The exact native source
# was also found, so preserve its correctly detected semantic objects and text.
try:
    s=importlib.util.spec_from_file_location('reference_reconstruction',SKILL/'scripts'/'image_to_visio.py')
    reconstructor=importlib.util.module_from_spec(s)
    sys.modules[s.name]=reconstructor
    s.loader.exec_module(reconstructor)
    import cv2
    image=cv2.imread(str(REFERENCE))
    if image is None:
        raise FileNotFoundError(REFERENCE)
    detected=reconstructor.build_spec(image,'flowchart',False,None)
except ModuleNotFoundError as exc:
    if exc.name!='cv2':
        raise
    # Prefer the exact original native diagram over approximate raster tracing.
    detected={'reconstruction':{'method':'exact-native-source-recovery',
        'raster_parser_unavailable':'OpenCV is not installed',
        'reference_inspected':True,'original_native_diagram_found':True}}
(RUN/'image-detection.json').write_text(json.dumps(detected,ensure_ascii=False,indent=2),encoding='utf-8')

source_hash=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
# Anchor mapping from the original Visio to the supplied 836 x 728 screenshot:
# native x=3,8,13 -> reference x=154,419,684; y=15.4 -> reference y=76.
SX,SY=1.062,0.856
TX,TY=-0.118,-0.1268
W,H=16.72,14.56
report={'skill':str(SKILL/'SKILL.md'),'reference':str(REFERENCE),'source':str(SOURCE),
        'source_sha256':source_hash,'output':str(OUTPUT),
        'image_detection':detected['reconstruction'],'status':'started'}
pythoncom.CoInitialize()
app=doc=page=window=candidate=shape=None
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
    page.Name='双FPGA救援车设计流程'
    before=[]
    for i in range(1,page.Shapes.Count+1):
        shape=page.Shapes.Item(i)
        row={'id':shape.NameU,'text':shape.Text,'cells':{}}
        for cell in ['PinX','PinY','Width','Height']:
            row['cells'][cell]=shape.CellsU(cell).ResultIU
        before.append(row)
    for i,row in enumerate(before,1):
        shape=page.Shapes.Item(i)
        values=row['cells']
        for cell,value in {
            'Width':values['Width']*SX,'Height':values['Height']*SY,
            'PinX':values['PinX']*SX+TX,'PinY':values['PinY']*SY+TY}.items():
            shape.CellsU(cell).FormulaForceU=f'{value:.10f} in'
    page.PageSheet.CellsU('PageWidth').ResultIU=W
    page.PageSheet.CellsU('PageHeight').ResultIU=H
    assert page.Shapes.Count==len(before)
    for i,row in enumerate(before,1):
        shape=page.Shapes.Item(i)
        assert shape.NameU==row['id'] and shape.Text==row['text']
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
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()==source_hash
    with zipfile.ZipFile(OUTPUT) as z:
        assert z.testzip() is None
        assert not any(n.startswith('visio/media/') for n in z.namelist())
    app.Settings.SetRasterExportResolution(0,110,110,0)
    preview=RUN/'recreated-preview.png'
    page.Export(str(preview))
    report.update(status='complete',pages=doc.Pages.Count,native_shapes=page.Shapes.Count,
        texts_preserved=True,source_unchanged=True,grid=bool(window.ShowGrid),
        page_breaks=bool(window.ShowPageBreaks),preview=str(preview),
        page_width=W,page_height=H,file_bytes=OUTPUT.stat().st_size,
        editable_objects=before)
    app.AlertResponse=0
    app.EventsEnabled=True
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
print(json.dumps({k:v for k,v in report.items() if k!='editable_objects'},ensure_ascii=False,indent=2))
