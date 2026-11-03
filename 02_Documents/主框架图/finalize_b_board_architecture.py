from pathlib import Path
import json
import win32com.client
import win32process

ROOT=Path(__file__).parent
RUN=ROOT/'.visio-runs/b_board_architecture'
spec=json.loads((ROOT/'B板整体架构图.json').read_text(encoding='utf-8'))
report=json.loads((RUN/'result.json').read_text(encoding='utf-8'))
doc=win32com.client.GetObject(report['output'])
app=doc.Application
assert win32process.GetWindowThreadProcessId(app.WindowHandle32)[1]==report['owned_pid']
page=doc.Pages.Item(1)
app.EventsEnabled=False
for c in spec['pages'][0]['connections']:
    if c['id'] not in ['hsv_to_mailbox','npu_to_mailbox']: continue
    page.Shapes.ItemU(c['id']).Delete()
    s=page.DrawPolyline(c['points'],8)
    s.NameU=c['id']
    assert s.OneD
    for k,v in {'LineColor':'RGB(32,32,32)','LineWeight':'0.75 pt','LinePattern':'2',
                'EndArrow':'4','EndArrowSize':'0','BeginArrow':'0','FillPattern':'0'}.items():
        s.CellsU(k).FormulaU=v
    s.CellsU('BeginX').GlueToPos(page.Shapes.ItemU(c['from']),c['fromX'],c['fromY'])
    s.CellsU('EndX').GlueToPos(page.Shapes.ItemU(c['to']),c['toX'],c['toY'])
doc.Save()
app.Settings.SetRasterExportResolution(0,80,80,0)
page.Export(str(RUN/'preview.png'))
app.EventsEnabled=True;app.Visible=True
app.ActiveWindow.ViewFit=1
report['routed_corridors_verified_pending']=True
(RUN/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print('Two editable connectors routed through reserved corridors; document saved.')
