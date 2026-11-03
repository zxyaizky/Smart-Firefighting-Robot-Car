import copy
import importlib.util
import json
from collections import Counter
from pathlib import Path
import zipfile
import xml.etree.ElementTree as E

root=Path(__file__).parent
final=root/'NPU网络调度与权重参数加载.vsdx'
plan=json.loads((root/'NPU网络调度与权重参数加载_绘图计划.json').read_text(encoding='utf-8'))
ns={'v':'http://schemas.microsoft.com/office/visio/2012/main'}
actual_plan=copy.deepcopy(plan)
with zipfile.ZipFile(final) as z:
    assert z.testzip() is None
    for n in z.namelist():
        if n.endswith('.xml'):
            E.fromstring(z.read(n))
    pages=E.fromstring(z.read('visio/pages/pages.xml')).findall('v:Page',ns)
    assert len(pages)==1
    page=E.fromstring(z.read('visio/pages/page1.xml'))
    shapes=page.findall('v:Shapes/v:Shape',ns)
    by_name={s.get('NameU'):s for s in shapes}
    assert len(shapes)==len(plan['shapes'])+len(plan['connectors'])
    connections=page.findall('v:Connects/v:Connect',ns)
    counts=Counter(c.get('FromSheet') for c in connections)
    cell=lambda s,n: s.find(f"v:Cell[@N='{n}']",ns)
    number=lambda s,n: float(cell(s,n).get('V'))
    for expected in plan['shapes']:
        s=by_name[expected['id']]
        actual=''.join(s.find('v:Text',ns).itertext()) if s.find('v:Text',ns) is not None else ''
        assert actual.rstrip('\r\n')==expected.get('text','').rstrip('\r\n'), (expected['id'],actual)
        if expected.get('preferredSource')=='stencil':
            assert s.get('Master'), expected['id']
        for key,cellname in [('x','PinX'),('y','PinY'),('width','Width'),('height','Height')]:
            assert abs(number(s,cellname)-expected[key])<1e-6
    for conn in actual_plan['connectors']:
        s=by_name[conn['id']]
        assert counts[s.get('ID')]==2
        for end,name in [('BeginX','from'),('EndX','to')]:
            match=[c for c in connections if c.get('FromSheet')==s.get('ID') and c.get('FromCell')==end]
            assert len(match)==1 and match[0].get('ToSheet')==by_name[conn[name]].get('ID')
        if conn.get('dashed'):
            assert number(s,'LinePattern')==2
        points=[]
        for row in s.findall("v:Section[@N='Geometry']/v:Row",ns):
            if row.get('T') not in ['MoveTo','LineTo']:
                continue
            points.extend([number(s,'PinX')+number(row,'X')-number(s,'LocPinX'),
                           number(s,'PinY')+number(row,'Y')-number(s,'LocPinY')])
        assert len(points)>=4
        conn['points']=points
    windows=E.fromstring(z.read('visio/windows.xml'))
    window=windows.find('v:Window',ns)
    assert window.find('v:ShowGrid',ns).text=='0'
    assert window.find('v:ShowPageBreaks',ns).text=='0'
    assert not any(n.startswith('visio/media/') for n in z.namelist())

spec=importlib.util.spec_from_file_location('layout',r'C:\Users\lx292\.codex\skills\visio-template-drawing\scripts\validate_plan_layout.py')
layout=importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
findings=layout.validate_page(actual_plan)
assert not findings, findings
handoff=root/'.visio-runs'/'npu_schedule_handoff_20261031'
result=json.loads((handoff/'result.json').read_text(encoding='utf-8-sig'))
recovery=json.loads((handoff/'recovery.json').read_text(encoding='utf-8-sig'))
assert result['success'] and result['saved'] and result['retained']
assert not result['leftovers'] and not result['cleanup_errors']
report=dict(output=str(final),single_page=True,shapes=len(shapes),
    native_glued_connectors=len(plan['connectors']),glued_endpoints=len(connections),
    texts_match=True,actual_geometry_preflight=findings,grid=False,page_breaks=False,
    embedded_rasters=False,render_fallbacks=[],handoff_result=result['status'],
    watchdog=recovery,run_directory=str(handoff),
    rtl_base=r'C:\Users\lx292\Desktop\qiansai_last\lab_ex3_osd_SC500_720\lab_ex3_osd',
    sources=['npu_u33_mcu_bridge.v','npu_param_loader.v','npu_ddr_scheduler.v',
             'npu_ddr_read_bridge.v','npu_model_config.vh','npu_network_top.v',
             'npu_sequencer.v','weight_sdram_dma.v','design_top_wrapper.v'])
(root/'NPU网络调度与权重参数加载_核对.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2))
