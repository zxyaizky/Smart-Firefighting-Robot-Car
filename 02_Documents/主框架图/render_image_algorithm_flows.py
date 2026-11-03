"""Render the eight algorithm pages in one owned native Visio document."""
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
BOARD=Path(r'C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B')
SKILL=Path(r'C:\Users\lx292\.codex\skills\visio-skill')
RUN=ROOT/'.visio-runs'/'eight_algorithm_flows'
OUTPUT=ROOT/'图像采集与处理_八算法流程图.vsdx'
SPEC_PATH=ROOT/'图像采集与处理_八算法流程图.json'
if OUTPUT.exists():
    raise FileExistsError(OUTPUT)
SPEC=json.loads(SPEC_PATH.read_text(encoding='utf-8'))
assert len(SPEC['pages'])==8
preflight=json.loads((RUN/'preflight.json').read_text(encoding='utf-8'))
assert not preflight
sources=[BOARD/'td_project/camera_to_dsi_display_lidar.al',
    BOARD/'firmware/linux_wifi/lidar_hdmi/rtl/design_top_wrapper.v',
    BOARD/'firmware/linux_wifi/lidar_hdmi/DISPLAY_EFFECTS.md',
    BOARD/'td_project/import/rgb2ycbcr.v',BOARD/'td_project/import/Sobel_Edge_Detector.v',
    BOARD/'firmware/linux_wifi/lidar_hdmi/rtl/rescue/VIP_Gray_Median_Filter_720p.v',
    BOARD/'firmware/linux_wifi/lidar_hdmi/rtl/rescue/rgb_quantize_4.v',
    BOARD/'user_source/hdl_source/histogram_equalizer_720p.v',
    BOARD/'user_source/hdl_source/motion_frame_diff.v',
    BOARD/'user_source/hdl_source/awb.v',BOARD/'user_source/hdl_source/auto_exposure.v',
    BOARD/'user_source/hdl_source/isp/isp_top.v',
    BOARD/'user_source/hdl_source/uics500_cfg/uicfgcs500_720p.v']
sys.path.insert(0,str(SKILL/'scripts'))
s=importlib.util.spec_from_file_location('alg_visio_engine',SKILL/'scripts'/'New-VisioDiagram.py')
engine=importlib.util.module_from_spec(s);sys.modules[s.name]=engine;s.loader.exec_module(engine)
report={'output':str(OUTPUT),'spec':str(SPEC_PATH),'skill':str(SKILL/'SKILL.md'),
    'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    'status':'started','pages':[],'preflight_findings':preflight,'rtl_modified':False,
    'hardware_builds_performed':False}
pythoncom.CoInitialize()
app=doc=page=shape=connector=candidate=window=None
objects={}
retained=False
try:
    app=win32com.client.DispatchEx('Visio.Application')
    app.Visible=False;app.EventsEnabled=False;app.AlertResponse=2
    report['owned_pid']=win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]
    doc=app.Documents.Add('')
    for index,p in enumerate(SPEC['pages'],1):
        page=doc.Pages.Item(1) if index==1 else doc.Pages.Add()
        page.Name=p['name']
        page.PageSheet.CellsU('PageWidth').ResultIU=p['pageWidth']
        page.PageSheet.CellsU('PageHeight').ResultIU=p['pageHeight']
        objects={}
        for n in p['nodes']:
            shape=engine.add_node(page,n,{})
            shape.NameU=n['id']
            for key,value in {'LineWeight':'0.65 pt','Char.Color':'RGB(0,0,0)',
                'Char.Style':'0','Char.AsianFont':'FONT("Microsoft YaHei")',
                'LeftMargin':'0.06 in','RightMargin':'0.06 in',
                'TopMargin':'0.035 in','BottomMargin':'0.035 in'}.items():
                shape.CellsU(key).FormulaU=value
            if n['shape']=='roundrect':shape.CellsU('Rounding').FormulaU='0.08 in'
            objects[n['id']]=shape
        for c in p['connections']:
            engine.add_connection(app,page,objects,c)
            connector=page.Shapes.Item(page.Shapes.Count);connector.NameU=c['id']
            connector.CellsU('BeginX').GlueToPos(objects[c['from']],c['fromX'],c['fromY'])
            connector.CellsU('EndX').GlueToPos(objects[c['to']],c['toX'],c['toY'])
            connector.CellsU('EndArrowSize').FormulaU='0'
            if c.get('dashed'):connector.CellsU('LinePattern').FormulaU='2'
            connector=None
        for l in p['labels']:
            shape=engine.add_label(page,l);shape.NameU=l['id']
            for key,value in {'FillPattern':'0','LinePattern':'0','Char.Color':'RGB(0,0,0)',
                'Char.Style':'0','Char.AsianFont':'FONT("Microsoft YaHei")',
                'LeftMargin':'0 in','RightMargin':'0 in','TopMargin':'0 in','BottomMargin':'0 in'}.items():
                shape.CellsU(key).FormulaU=value
            objects[l['id']]=shape
        assert page.Connects.Count==2*len(p['connections'])
        for n in p['nodes']+p['labels']:
            assert objects[n['id']].Text.rstrip('\r\n')==n['text'].rstrip('\r\n'),n['id']
        assert objects['end'].CellsU('PinY').ResultIU <= min(
            objects[n['id']].CellsU('PinY').ResultIU for n in p['nodes'] if not n.get('container'))
        preview=RUN/f'page-{index:02d}.png'
        app.Settings.SetRasterExportResolution(0,65,65,0)
        page.Export(str(preview))
        entry=dict(index=index,name=page.Name,editable_shapes=page.Shapes.Count,
            glued_connectors=len(p['connections']),glued_endpoints=page.Connects.Count,
            width=p['pageWidth'],height=p['pageHeight'],preview=str(preview))
        report['pages'].append(entry)
        print(f"PAGE {index}/8: {page.Name}, {page.Shapes.Count} editable objects",flush=True)
        objects.clear();shape=connector=page=None
    assert doc.Pages.Count==8
    for i in range(1,app.Windows.Count+1):
        candidate=app.Windows.Item(i)
        if candidate.Type==1 and candidate.Document.ID==doc.ID:
            window=candidate;break
    if window is None:raise RuntimeError('Drawing window not found')
    window.ShowGrid=False;window.ShowPageBreaks=False;window.ShowGuides=False
    window.Page=doc.Pages.Item(1)
    window.ViewFit=1
    doc.SaveAs(str(OUTPUT))
    assert doc.Saved and OUTPUT.stat().st_size>0
    with zipfile.ZipFile(OUTPUT) as z:
        assert z.testzip() is None and not any(n.startswith('visio/media/') for n in z.namelist())
    assert all(hashlib.sha256(p.read_bytes()).hexdigest()==report['source_hashes'][str(p)] for p in sources)
    report.update(status='complete',page_count=doc.Pages.Count,texts_verified=True,
        all_end_nodes_lowest=True,source_files_unchanged=True,grid=bool(window.ShowGrid),
        page_breaks=bool(window.ShowPageBreaks),displayed_page=window.Page.Name,file_bytes=OUTPUT.stat().st_size)
    app.EventsEnabled=True;app.AlertResponse=0;app.Visible=True
    window.Activate();window.ViewFit=1;retained=True;report['final_window_retained']=True
except Exception:
    report.update(status='failed',error=traceback.format_exc());raise
finally:
    (RUN/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    if not retained:
        if doc is not None:doc.Saved=True;doc.Close()
        if app is not None:app.Quit()
    objects.clear();shape=connector=candidate=window=page=doc=app=None
    gc.collect();pythoncom.CoUninitialize()
print(json.dumps({k:v for k,v in report.items() if k not in ['source_hashes','pages']},ensure_ascii=False,indent=2))
