from pathlib import Path
import hashlib
import importlib.util
import json
import zipfile
import xml.etree.ElementTree as E

ROOT=Path(__file__).parent
RUN=ROOT/'.visio-runs'/'eight_algorithm_flows'
OUTPUT=ROOT/'图像采集与处理_八算法流程图.vsdx'
SPEC=json.loads((ROOT/'图像采集与处理_八算法流程图.json').read_text(encoding='utf-8'))
PLANS=json.loads((RUN/'layout-plan.json').read_text(encoding='utf-8'))['pages']
ns={'v':'http://schemas.microsoft.com/office/visio/2012/main'}
num=lambda s,n:float(s.find(f"v:Cell[@N='{n}']",ns).get('V'))
v=importlib.util.spec_from_file_location('layout',r'C:\Users\lx292\.codex\skills\visio-template-drawing\scripts\validate_plan_layout.py')
layout=importlib.util.module_from_spec(v);v.loader.exec_module(layout)
findings=[];results=[]
with zipfile.ZipFile(OUTPUT) as z:
    assert z.testzip() is None
    for name in z.namelist():
        if name.endswith('.xml'):E.fromstring(z.read(name))
    listed=E.fromstring(z.read('visio/pages/pages.xml')).findall('v:Page',ns)
    assert len(listed)==8
    assert not any(n.startswith('visio/media/') for n in z.namelist())
    master=E.fromstring(z.read('visio/masters/master1.xml')).find('v:Shapes/v:Shape',ns)
    base={r.get('IX'):r for r in master.findall("v:Section[@N='Geometry']/v:Row",ns)}
    for index,(spec,plan,listed_page) in enumerate(zip(SPEC['pages'],PLANS,listed),1):
        assert listed_page.get('Name')==spec['name']
        page=E.fromstring(z.read(f'visio/pages/page{index}.xml'))
        shapes={s.get('NameU'):s for s in page.findall('v:Shapes/v:Shape',ns)}
        connects=page.findall('v:Connects/v:Connect',ns)
        assert len(shapes)==len(spec['nodes'])+len(spec['labels'])+len(spec['connections'])
        assert len(connects)==2*len(spec['connections'])
        for n in spec['nodes']+spec['labels']:
            s=shapes[n['id']];t=s.find('v:Text',ns)
            actual=''.join(t.itertext()).rstrip('\r\n') if t is not None else ''
            assert actual==n['text'].rstrip('\r\n'),(index,n['id'])
        end_y=num(shapes['end'],'PinY')
        assert all(end_y <= num(shapes[n['id']],'PinY')+1e-5 for n in spec['nodes'] if not n.get('container'))
        for c in plan['connectors']:
            s=shapes[c['id']]
            for field,target in [('BeginX','from'),('EndX','to')]:
                matches=[a for a in connects if a.get('FromSheet')==s.get('ID') and a.get('FromCell')==field]
                assert len(matches)==1 and matches[0].get('ToSheet')==shapes[c[target]].get('ID')
            overrides={r.get('IX'):r for r in s.findall("v:Section[@N='Geometry']/v:Row",ns)}
            points=[]
            for ix in sorted(set(base)|set(overrides),key=int):
                b=base.get(ix);o=overrides.get(ix)
                if o is not None and o.get('Del')=='1':continue
                xy={a.get('N'):float(a.get('V')) for a in ([] if b is None else b.findall('v:Cell',ns))}
                if o is not None:xy.update({a.get('N'):float(a.get('V')) for a in o.findall('v:Cell',ns)})
                points.extend([num(s,'PinX')+xy['X']-num(s,'LocPinX'),num(s,'PinY')+xy['Y']-num(s,'LocPinY')])
            c['points']=points
        result=layout.validate_page(plan)
        findings.extend([dict(page=spec['name'],**r) for r in result])
        results.append(dict(page=spec['name'],shapes=len(shapes),glued_endpoints=len(connects),findings=len(result)))
    window=E.fromstring(z.read('visio/windows.xml')).find('v:Window',ns)
    assert window.find('v:ShowGrid',ns).text=='0'
    assert window.find('v:ShowPageBreaks',ns).text=='0'
    assert window.get('Page')==listed[0].get('ID')

(RUN/'actual-layout.json').write_text(json.dumps({'pages':PLANS},ensure_ascii=False,indent=2),encoding='utf-8')
(RUN/'actual-layout-findings.json').write_text(json.dumps(findings,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'pages':results,'findings':findings},ensure_ascii=False,indent=2))
assert not findings,findings
report=json.loads((RUN/'result.json').read_text(encoding='utf-8'))
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in report['source_hashes'].items())
report.update(actual_geometry_preflight=findings,saved_xml_valid=True,source_files_unchanged=True,
              page_order_verified=True,native_text_and_connections_verified=True)
(RUN/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
