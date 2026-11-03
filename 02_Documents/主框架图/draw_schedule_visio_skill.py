"""Create the focused NPU drawing using the explicitly requested visio-skill."""
import copy
import gc
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import traceback

import pythoncom
import win32com.client
import win32process

ROOT=Path(__file__).parent
SKILL=Path(r'C:\Users\lx292\.codex\skills\visio-skill')
RTL=Path(r'C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd\td_project\import')
OUT=ROOT/'NPU网络调度与权重参数加载_visio-skill版.vsdx'
SPEC=ROOT/'NPU网络调度与权重参数加载_visio-skill版.json'
AUDIT=ROOT/'NPU网络调度与权重参数加载_visio-skill版_核对.json'


def load_module(name,path):
    s=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(s)
    sys.modules[name]=m
    s.loader.exec_module(m)
    return m


sys.path.insert(0,str(SKILL/'scripts'))
engine=load_module('requested_visio_engine',SKILL/'scripts'/'New-VisioDiagram.py')
rtl_engine=load_module('requested_rtl_engine',SKILL/'scripts'/'verilog_to_visio.py')
filenames=['npu_network_top.v','npu_top_with_sdram_dma.v','npu_core_top.v',
    'npu_ddr_subsystem.v','npu_sequencer.v','npu_u33_mcu_bridge.v',
    'npu_param_loader.v','npu_ddr_scheduler.v','npu_ddr_read_bridge.v',
    'weight_sdram_dma.v','weight_buffer.v','bias_buffer.v','conv_engine_top.v','bcu.v']
paths=[RTL/n for n in filenames if (RTL/n).is_file()]
modules=rtl_engine.parse_modules(paths)
auto_specs={top:rtl_engine.build_spec(modules[top],modules)
    for top in ['npu_ddr_subsystem','npu_core_top','npu_top_with_sdram_dma']}
(ROOT/'NPU调度与参数加载_RTL自动展开.json').write_text(
    json.dumps(auto_specs,ensure_ascii=False,indent=2),encoding='utf-8')

# This subject crosses several RTL hierarchy levels. Use the verified functional
# grouping, with the skill's node/connection engine, rather than one dense netlist.
plan=json.loads((ROOT/'NPU网络调度与权重参数加载_绘图计划.json').read_text(encoding='utf-8'))
sx=1.12
page_spec={'name':'网络调度与权重参数加载','nodes':[],'labels':[],'connections':[]}
for item in plan['shapes']:
    node={'id':item['id'],'text':item.get('text',''),
        'x':sx*(item['x']-item['width']/2),'y':item['y']-item['height']/2,
        'w':sx*item['width'],'h':item['height'],
        'fontName':'Microsoft YaHei','fontSize':item.get('fontSize',18),
        'fill':item.get('fill','#FFFFFF'),'line':item.get('line','#202020'),
        'bold':item.get('bold',False)}
    if item['kind']=='text':
        page_spec['labels'].append(node)
    else:
        node['shape']='roundrect'
        node['container']=item.get('shapeIntent')=='container'
        node['fontSize']=18
        page_spec['nodes'].append(node)
for edge in plan['connectors']:
    conn=copy.deepcopy(edge)
    conn.update(fontName='Microsoft YaHei',fontSize=14,endArrow=4)
    page_spec['connections'].append(conn)
spec={'title':'NPU 网络调度与权重参数加载','pageWidth':24*sx,
      'pageHeight':17.5,'pages':[page_spec]}
SPEC.write_text(json.dumps(spec,ensure_ascii=False,indent=2),encoding='utf-8')
if OUT.exists():
    raise FileExistsError(OUT)

pythoncom.CoInitialize()
app=doc=page=window=shape=connector=None
shapes={}
kept=False
evidence={'skill':str(SKILL/'SKILL.md'),'output':str(OUT),'spec':str(SPEC),
    'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
    'parsed_hierarchy':{name:[{'module':i.module,'instance':i.name,'ports':i.connections}
        for i in modules[name].instances] for name in auto_specs},
    'status':'started'}
try:
    # Never attach to or close the user's existing Visio application.
    app=win32com.client.DispatchEx('Visio.Application')
    app.Visible=False
    app.AlertResponse=2
    app.EventsEnabled=False
    evidence['owned_pid']=win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]
    doc=app.Documents.Add('')
    page=doc.Pages.Item(1)
    page.Name=page_spec['name']
    page.PageSheet.CellsU('PageWidth').ResultIU=spec['pageWidth']
    page.PageSheet.CellsU('PageHeight').ResultIU=spec['pageHeight']
    for n in page_spec['nodes']:
        shape=engine.add_node(page,n,{})
        shape.NameU=n['id']
        shape.CellsU('Rounding').FormulaU='0.10 in'
        shape.CellsU('LineWeight').FormulaU='1 pt'
        shape.CellsU('Char.Color').FormulaU='RGB(0,0,0)'
        shapes[n['id']]=shape
    for c in page_spec['connections']:
        engine.add_connection(app,page,shapes,c)
        connector=page.Shapes.Item(page.Shapes.Count)
        connector.NameU=c['id']
        connector.CellsU('BeginX').GlueToPos(shapes[c['from']],c['fromX'],c['fromY'])
        connector.CellsU('EndX').GlueToPos(shapes[c['to']],c['toX'],c['toY'])
        if c.get('dashed'):
            connector.CellsU('LinePattern').FormulaU='2'
        connector=None
    for label in page_spec['labels']:
        shape=engine.add_label(page,label)
        shape.NameU=label['id']
        shape.CellsU('LinePattern').FormulaU='0'
        shape.CellsU('FillPattern').FormulaU='0'
        shape.CellsU('Char.Color').FormulaU='RGB(0,0,0)'
        if label['bold']:
            shape.CellsU('Char.Style').FormulaU='1'
        shapes[label['id']]=shape
    assert doc.Pages.Count==1
    assert page.Shapes.Count==len(plan['shapes'])+len(plan['connectors'])
    assert page.Connects.Count==2*len(plan['connectors'])
    for expected in plan['shapes']:
        assert shapes[expected['id']].Text.rstrip('\r\n')==expected.get('text','').rstrip('\r\n')
    # Use only the drawing window belonging to this new document.
    for index in range(1,app.Windows.Count+1):
        candidate=app.Windows.Item(index)
        if candidate.Type==1 and candidate.Document.ID==doc.ID:
            window=candidate
            break
    if window is None:
        raise RuntimeError('Owned drawing window not found')
    window.ShowGrid=False
    window.ShowPageBreaks=False
    window.ShowGuides=False
    window.ViewFit=1
    doc.SaveAs(str(OUT))
    assert OUT.stat().st_size>0 and doc.Saved
    evidence.update(status='complete',pages=doc.Pages.Count,editable_shapes=page.Shapes.Count,
        glued_endpoints=page.Connects.Count,connectors=len(plan['connectors']),
        grid=bool(window.ShowGrid),page_breaks=bool(window.ShowPageBreaks),
        no_raster_content=True,texts_match=True,file_bytes=OUT.stat().st_size)
    app.EventsEnabled=True
    app.AlertResponse=0
    app.Visible=True
    window.Activate()
    window.ViewFit=1
    kept=True
    evidence['final_window_retained']=True
except Exception:
    evidence.update(status='failed',error=traceback.format_exc())
    raise
finally:
    AUDIT.write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    if not kept:
        if doc is not None:
            doc.Saved=True
            doc.Close()
        if app is not None:
            app.Quit()
    shapes.clear()
    shape=connector=window=page=doc=app=None
    gc.collect()
    pythoncom.CoUninitialize()

print(json.dumps({k:v for k,v in evidence.items() if k not in ['source_hashes','parsed_hierarchy']},ensure_ascii=False,indent=2))
