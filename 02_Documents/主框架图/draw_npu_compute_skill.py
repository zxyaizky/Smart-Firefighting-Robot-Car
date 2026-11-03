"""Customize the skill's RTL expansion, then render through its Visio COM helpers."""
from pathlib import Path
import hashlib
import importlib.util
import json
import sys
import zipfile
import win32com.client

OUT=Path(__file__).resolve().parent
SKILL=Path(r'C:\Users\lx292\.codex\skills\visio-skill')
RTL=OUT.parent/'lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import'
W,H=28.2,18.4
BLUE,PALE,ORANGE,WHITE,BLACK='#CBE5FE','#E8F3FE','#FFCB99','#FFFFFF','#000000'
auto=json.loads((OUT/'NPU核心计算架构_自动展开.json').read_text(encoding='utf-8'))
page_spec={'name':'NPU核心计算架构图','nodes':[],'labels':[],'lines':[],'connections':[]}
nodes,labels,segments=page_spec['nodes'],page_spec['labels'],page_spec['lines']
edges=[]


def label(key,x,y,w,h,text,size=13,bold=False):
    labels.append({'id':key,'x':x-w/2,'y':y-h/2,'w':w,'h':h,'text':text,
                   'fontName':'Microsoft YaHei','fontSize':size,'bold':bold})


def rect(key,x,y,w,h,fill=ORANGE,z=5):
    nodes.append({'id':key,'text':'','x':x-w/2,'y':y-h/2,'w':w,'h':h,
                  'shape':'roundrect','fill':fill,'line':BLACK,'fontSize':15,'zOrder':z})


def block(key,x,y,w,h,title,detail,external=False,size=16):
    rect(key,x,y,w,h,WHITE if external else ORANGE)
    label(key+'_title',x,y+.23,w-.2,.4,title,size,True)
    label(key+'_detail',x,y-.27,w-.2,.61,detail,12)


def path(key,points,dashed=False,arrow=True):
    edges.append({'id':key,'points':points,'control':dashed})
    for i,(a,b) in enumerate(zip(points,points[1:])):
        assert a!=b,key
        segments.append({'id':key+'_'+str(i),'x1':a[0],'y1':a[1],
                         'x2':b[0],'y2':b[1],'line':BLACK,'lineWeight':1.4,
                         'dash':2 if dashed else 0,
                         'endArrow':13 if arrow and i==len(points)-2 else 0})


rect('page_white_background',W/2,H/2,W,H,WHITE,0)
rect('compute_boundary',14.4,9.55,19.4,12.5,BLUE,1)
rect('pe_boundary',13.725,9.0,8.85,9.1,PALE,2)
label('title',14.1,17.35,26.5,.65,'NPU 核心计算架构图',29,True)
label('subtitle',14.1,16.72,26.3,.36,
      'conv_engine_top / pe_array  ·  8 位特征 × 8 位有符号权重  ·  32 位跨通道累加',15)
label('engine_title',14.4,15.43,18.4,.42,'卷积计算引擎  ·  conv_engine_top',19,True)
label('pe_title',11.9,13.05,4.6,.45,'PE 阵列  ·  pe_array',17,True)

# Context interfaces and local parameter storage.
block('feature_in',2.25,10.7,2.8,1.3,'输入特征缓存','PING / PONG\n8 位像素 + valid',True,15)
block('param_dma',2.25,14.1,2.8,1.15,'参数 DMA 接口','权重 / Bias 装载\n更新使能与地址',True,15)
block('weight_buffer',6.8,14.1,3.2,1.15,'片上权重缓存','weight_buffer\n16 × 9 × 8 位输出',size=15)
block('bias_buffer',21.0,14.1,3.7,1.15,'片上偏置缓存','bias_buffer\n每次输出两通道 Bias（64 位）',size=16)
path('dma_weights',[(3.65,14.1),(5.2,14.1)])
label('weight_dma_label',4.43,14.43,1.55,.28,'144 bit / 写地址',10)
path('dma_bias',[(3.65,14.35),(4.25,14.35),(4.25,14.95),(21.0,14.95),(21.0,14.675)])
label('bias_dma_label',17.1,15.16,4.0,.27,'32 位 Bias 写入 / 更新',11)

block('window',6.8,10.7,3.2,1.3,'卷积窗口生成','line_buffer_conv\n1×1 / 3×3、零填充与坐标',size=15)
path('pixel_read',[(3.65,10.7),(5.2,10.7)])
label('pixel_label',4.43,11.05,1.55,.28,'pixel[7:0]',11)
path('pixel_ready',[(4.7,9.5),(2.25,9.5),(2.25,10.05)],True)
label('pixel_ready_label',3.5,9.22,2.8,.3,'pixel_in_ready 读信用',11)

# Internal PE schedule: one queued window, two physical dot-product trees.
block('window_hold',11.5,11.4,3.0,1.1,'窗口保持 / 弹性缓冲','当前窗口 + 1 个待处理窗口\n72 位窗口，x/y 与 Cin 标志',size=14)
block('round_select',15.8,11.4,3.0,1.1,'轮次调度 / 权重选通','每轮选择 2 个输出通道\n最多 8 轮；裁剪无效通道',size=14)
block('mac0',11.5,9.3,3.0,1.25,'物理 MAC 树 0','mac_tree_3x3\n9 项点积 / 4 级流水\n20 位有符号输出',size=16)
block('mac1',15.8,9.3,3.0,1.25,'物理 MAC 树 1','mac_tree_3x3\n9 项点积 / 4 级流水\n20 位有符号输出',size=16)
block('collect',13.65,7.2,7.3,1.0,'带轮次标记的结果收集 / 原子提交',
      '两路 MAC 结果 → 16 × 20 位结果寄存器；提交时保留同一窗口的坐标与 Cin 标志',size=16)
block('psum',13.65,5.35,7.3,1.15,'16 个逻辑通道的部分和累加',
      'channel_accumulator：2 行 Tile 的 32 位 PSUM RAM\n首 Cin 初始化 → 后续 Cin 累加 → 末 Cin 输出最终和',size=17)
path('window_to_hold',[(8.4,10.7),(8.85,10.7),(8.85,11.4),(10.0,11.4)])
label('window_bus_label',9.15,11.77,1.45,.28,'72 bit 窗口',10)
path('hold_round',[(13.0,11.4),(14.3,11.4)])
label('hold_round_label',13.65,11.77,1.3,.28,'握手 / 广播',10)
path('weights_select',[(8.4,14.1),(15.8,14.1),(15.8,11.95)])
label('weights_select_label',12.2,14.39,5.3,.3,'16 × 9 × 8 位权重总线',12)
path('round_mac0',[(15.25,10.85),(15.25,10.25),(11.5,10.25),(11.5,9.925)])
path('round_mac1',[(15.8,10.85),(15.8,9.925)])
label('mac_feed_label',13.05,10.48,4.0,.25,'共享窗口 / 各 72 位权重',10)
path('mac0_collect',[(11.5,8.675),(11.5,7.7)])
path('mac1_collect',[(15.8,8.675),(15.8,7.7)])
label('mac0_width',12.12,8.15,1.05,.26,'20 bit',11)
label('mac1_width',16.43,8.15,1.05,.26,'20 bit',11)
path('collect_psum',[(13.65,6.7),(13.65,5.925)])
label('commit_label',15.1,6.3,2.6,.28,'16 路同时提交',11)

# Fused arithmetic and selectable pooling tail.
block('activation',21.0,10.7,3.7,1.4,'偏置 + 激活 + 量化',
      'activation_quant_fused\n2 路算术单元复用 16 通道\n移位 / 饱和至 uint8',size=16)
block('pool',21.0,7.45,3.7,1.25,'可选 2×2 最大池化',
      'line_buffer_pool\n当前 Tile 坐标按行序直接传递',size=16)
block('output_select',21.0,5.3,3.7,1.3,'输出选择与尾通道屏蔽',
      'cfg_pool_en 选择池化 / 直通\ni_oc_block_size 屏蔽无效通道',size=15)
block('feature_out',26.1,5.3,2.4,1.3,'输出特征写回','PING / PONG\n16 × 8 = 128 位',True,15)
path('psum_activation',[(17.3,5.35),(18.6,5.35),(18.6,10.7),(19.15,10.7)])
label('psum_bus',18.65,8.75,1.35,.6,'16 × 32 bit\n累加结果',10)
path('bias_pairs',[(21.0,13.525),(21.0,11.4)])
label('bias_pair_label',22.25,12.5,2.4,.55,'64 位 Bias pair\n偏置索引反馈',11)
path('quant_pool',[(21.0,10.0),(21.0,8.075)])
label('quant_width',21.95,9.05,1.85,.45,'128 bit\n16 × uint8',11)
path('pool_mux',[(21.0,6.825),(21.0,5.95)])
path('quant_bypass',[(22.85,10.7),(23.55,10.7),(23.55,5.6),(22.85,5.6)])
label('bypass_label',23.18,8.0,.8,.6,'不池化\n直通',10)
path('output_write',[(22.85,5.3),(24.9,5.3)])
label('output_data_label',23.87,4.85,2.1,.3,'128 bit / valid / x,y',10)

block('global_control',14.4,2.0,19.4,1.0,'层 / Tile 调度与流水排空控制',
      '来自 npu_sequencer / BCU：kernel_size、padding、首末 Cin、Tile 坐标、激活类型与量化移位；返回 ready / done / error',size=17)
path('representative_control',[(13.7,2.5),(13.7,3.65),(6.8,3.65),(6.8,10.05)],True)
label('control_bus_label',5.7,7.2,1.8,.7,'层参数 / Tile\n控制扇出概括',11)
label('footer',14.1,.65,26.3,.5,
      '基于当前综合路径绘制：仅 2 个物理 MAC 树；16 路累加器仍独立。当前池化重排为坐标直通，未画入仿真参考分支及未启用的整帧 / AXI 缓存。',11)

# Use the deterministic expansion as provenance, customizing the hierarchy to
# omit global debug ports and inactive branches and expose the physical PEs.
spec=dict(auto)
spec.update(title='NPU 核心计算架构图',pageWidth=W,pageHeight=H,
            pages=[page_spec],layout={'engine':'manual','checkCollisions':False},
            rtl_scope={'top':'conv_engine_top','expanded':['pe_array','mac_tree_3x3','channel_accumulator'],
                       'conditional_path':'POOL_REORDER_IMPL == 2; hardware path excludes MODEL_TECH reference'},
            logical_routes=edges)
json_path=OUT/'NPU核心计算架构图_蓝橙配色.json'
json_path.write_text(json.dumps(spec,ensure_ascii=False,indent=2),encoding='utf-8')
assert len({n['id'] for n in nodes})==len(nodes)
assert all(.0<=n['x'] and .0<=n['y'] and n['x']+n['w']<=W and n['y']+n['h']<=H for n in nodes)
assert all(0<=v['x'] and 0<=v['y'] and v['x']+v['w']<=W and v['y']+v['h']<=H for v in labels)
files=['conv_engine_top.v','pe_array.v','mac_tree_3x3.v','channel_accumulator.v',
       'activation_quant_fused.v','weight_buffer.v','bias_buffer.v','line_buffer_conv.v','line_buffer_pool.v']
checks={'pe_array.v':['localparam PHYSICAL_LANES = 2','round_reg*2+p','for (lane = 0; lane < NUM_CHANNELS'],
        'channel_accumulator.v':['TILE_ROWS = 2','reg signed [31:0] psum_ram','first_d1 ? mac_ext'],
        'conv_engine_top.v':['GEN_POOL_REORDER_DIRECT','assign pool_reorder_rdata = quant_out_bus','u_activation_quant','GEN_LANE_MASK'],
        'activation_quant_fused.v':['in_bias_pair','bias_pair_addr','8\'d255']}
for name,tokens in checks.items():
    s=(RTL/name).read_text(encoding='utf-8-sig')
    assert all(t in s for t in tokens),(name,tokens)

# Use the skill renderer in the active Visio session; its CLI finally/Quit would
# close the user's other diagrams, so invoke the drawing functions directly.
sys.path.insert(0,str(SKILL/'scripts'))
load=importlib.util.spec_from_file_location('visio_skill_renderer',SKILL/'scripts/New-VisioDiagram.py')
renderer=importlib.util.module_from_spec(load);load.loader.exec_module(renderer)
spec=json.loads(json_path.read_text(encoding='utf-8'))
app=win32com.client.GetActiveObject('Visio.Application')
app.Visible=True
doc=app.Documents.Add('')
page=doc.Pages.Item(1)
page.Name=page_spec['name']
page.PageSheet.CellsU('PageWidth').FormulaU=f'{W} in'
page.PageSheet.CellsU('PageHeight').FormulaU=f'{H} in'
created={}
for n in sorted(spec['pages'][0]['nodes'],key=lambda n:n.get('zOrder',5)):
    s=renderer.add_node(page,n,{})
    s.NameU=n['id']
    s.CellsU('Rounding').FormulaU='.08 in'
    s.CellsU('LineWeight').FormulaU='.9 pt'
    if n['id']=='page_white_background':
        s.CellsU('LinePattern').FormulaU='0'
    created[n['id']]=s
for route in spec['pages'][0]['lines']:
    s=renderer.add_line(page,route)
    s.NameU=route['id']
    s.CellsU('EndArrowSize').ResultIU=2
    s.SendToBack()
for l in spec['pages'][0]['labels']:
    s=renderer.add_label(page,l)
    s.NameU=l['id']
    for k,v in {'FillPattern':'0','LinePattern':'0','Char.AsianFont':'FONT("Microsoft YaHei")',
                'Char.Color':'RGB(0,0,0)','Char.Style':'1' if l.get('bold') else '0',
                'Para.HorzAlign':'1','VerticalAlign':'1','TopMargin':'0 in',
                'BottomMargin':'0 in','LeftMargin':'.02 in','RightMargin':'.02 in'}.items():
        s.CellsU(k).FormulaU=v
for key in ['pe_boundary','compute_boundary','page_white_background']:
    created[key].SendToBack()
app.ActiveWindow.Page=page
app.ActiveWindow.ShowGrid=False
app.ActiveWindow.ShowPageBreaks=False
assert doc.Pages.Count==1
target=OUT/'NPU核心计算架构图_蓝橙配色.vsdx'
doc.SaveAs(str(target))
app.Settings.SetRasterExportResolution(0,135,135,0)
for ext in ['.png','.svg']:
    page.Export(str(target.with_suffix(ext)))
with zipfile.ZipFile(target) as z:
    assert z.testzip() is None
    xml=z.read('visio/pages/page1.xml').decode('utf-8')
    assert all(t in xml for t in ['物理 MAC 树 0','物理 MAC 树 1','32 位 PSUM','2×2 最大池化'])
assert target.stat().st_size>0
audit={'source_sha256':{str(RTL/f):hashlib.sha256((RTL/f).read_bytes()).hexdigest() for f in files},
       'skill':str(SKILL/'SKILL.md'),'json':str(json_path),'single_page':True,
       'source_structure_and_vsdx':'PASS','native_shapes':page.Shapes.Count,
       'scope':'Drawing only; no RTL changes or new synthesis/board validation'}
(OUT/'NPU核心计算架构图_来源核对.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8')
app.ActiveWindow.DeselectAll()
app.ActiveWindow.SetViewRect(0,H,W,H)
print(json.dumps({'vsdx':str(target),'shapes':page.Shapes.Count,'check':'PASS'},ensure_ascii=False))
