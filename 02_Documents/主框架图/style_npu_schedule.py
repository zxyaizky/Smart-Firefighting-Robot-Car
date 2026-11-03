import json
from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET

root = Path(__file__).parent
plan = json.loads((root/'NPU网络调度与权重参数加载_绘图计划.json').read_text(encoding='utf-8'))
run = root/'.visio-runs'/'npu_schedule_20261031'
src = run/'rendered.vsdx'
dst = run/'styled-template.vsdx'
uri = 'http://schemas.microsoft.com/office/visio/2012/main'
ns = {'v':uri}
ET.register_namespace('',uri)
ET.register_namespace('r','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
control_ids = {c['id'] for c in plan['connectors'] if c.get('dashed')}
def cell(shape,name,value,formula=None):
    c = shape.find(f"v:Cell[@N='{name}']",ns)
    if c is None:
        c = ET.Element(f'{{{uri}}}Cell',{'N':name})
        shape.insert(0,c)
    c.set('V',str(value))
    c.attrib.pop('F',None)
    if formula:
        c.set('F',formula)

with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data=zin.read(item.filename)
        if item.filename=='visio/pages/page1.xml':
            page=ET.fromstring(data)
            for shape in page.findall('v:Shapes/v:Shape',ns):
                name=shape.get('NameU')
                if name in control_ids:
                    cell(shape,'LinePattern',2)
                if shape.get('Master') and name not in {c['id'] for c in plan['connectors']}:
                    for row in shape.findall("v:Section[@N='User']/v:Row",ns):
                        if row.get('N') in ['TopLeftOffset','TopRightOffset','BotLeftOffset','BotRightOffset']:
                            cell(row,'Value',0.12,'0.12 in')
            data=ET.tostring(page,encoding='utf-8',xml_declaration=True)
        elif item.filename=='visio/windows.xml':
            window=ET.fromstring(data)
            for w in window.findall('v:Window',ns):
                for tag in ['ShowGrid','ShowPageBreaks','ShowGuides','ShowConnectionPoints']:
                    node=w.find('v:'+tag,ns)
                    if node is None:
                        node=ET.SubElement(w,f'{{{uri}}}{tag}')
                    node.text='0'
                w.set('ViewScale','-1')
                w.set('ViewCenterX','12')
                w.set('ViewCenterY','8.75')
            data=ET.tostring(window,encoding='utf-8',xml_declaration=True)
        zout.writestr(item,data)

handoff={'page':plan['page'],'shapes':[],'connectors':[]}
(run/'handoff.json').write_text(json.dumps(handoff,ensure_ascii=False,indent=2),encoding='utf-8')
print(dst)
print('Native masters and endpoint glue preserved; control line style and page view settings applied.')
