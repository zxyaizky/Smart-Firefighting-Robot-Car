"""Actual streamed-RGB NPU preprocessing, as native Visio diagram objects."""
from pathlib import Path
import ast
import hashlib
import json
import zipfile
import win32com.client

OUT=Path(__file__).resolve().parent
RTL=OUT.parent/'lab_ex3_osd_SC500_720/lab_ex3_osd/td_project/import'
W,H=24.4,14.6
C={'navy':'RGB(0,0,0)','blue':'RGB(0,0,0)','ink':'RGB(0,0,0)',
   'muted':'RGB(55,55,55)','border':'RGB(50,50,50)',
   'light':'RGB(203,229,254)','panel':'RGB(203,229,254)',
   'white':'RGB(255,203,153)','paper':'RGB(255,255,255)','black':'RGB(0,0,0)'}
app=win32com.client.GetActiveObject('Visio.Application')
doc=app.Documents.Add('')
page=doc.Pages.Item(1)
page.Name='NPU预处理架构图'
for k,v in [('PageWidth',W),('PageHeight',H),('DrawingScale',1),('PageScale',1)]:
    page.PageSheet.CellsU(k).FormulaU=f'{v} in'
nodes,lines,panels={},[],[]
tree=ast.parse((OUT/'draw_blue_design_flow.py').read_text(encoding='utf-8'))
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)],
                        type_ignores=[]),'<Visio helpers>','exec'))


def block(key,x,y,w,title,detail,h=1.28,external=False):
    shape(key,x,y,w,h,fill='paper' if external else 'white')
    label(key+'_title',x,y+.24,w-.2,.39,title,17,'ink',True)
    label(key+'_detail',x,y-.27,w-.2,.52,detail,13)


label('title',12.2,13.92,23,.62,'NPU 图像预处理架构图',29,'ink',True)
label('subtitle',12.2,13.35,23,.34,
      '1280 × 720 RGB888 → 160 × 90 采样 → 160 × 120 补零布局 → CHW / PING',15)
for key,x,y,w,h,title in [
    ('video_domain',12.2,11.45,23.2,2.8,'视频时钟域  ·  clk_video'),
    ('npu_domain',12.2,5.75,23.2,3.25,'NPU 时钟域  ·  clk_npu'),
    ('format_panel',6.2,2.18,11.2,2.85,'输入张量布局'),
    ('commit_panel',18.2,2.18,11.2,2.85,'完整帧提交与推理启动')]:
    panels.append(shape(key,x,y,w,h,fill='panel'))
    label(key+'_title',x,y+h/2-.33,w-.3,.4,title,18,'ink',True)
setc(nodes['npu_domain_title']['shape'],'PinX','3.55 in')
setc(nodes['npu_domain_title']['shape'],'Width','4.35 in')

XS=[3.55,8.95,14.35,19.75]
UP=11.2
block('source',XS[0],UP,4.35,'原始 RGB 视频取流',
      'ISP / DDR 回读，OSD 之前\n1280 × 720 RGB888 + 帧元数据',external=True)
block('align',XS[1],UP,4.35,'读使能与帧起点对齐',
      'read_en 延迟 2 拍匹配 RGB\nVS 边沿布防，等待有效图像 / 元数据')
block('admit',XS[2],UP,4.35,'帧准入与来源信息锁存',
      '检查 NPU busy、FIFO 与元数据握手\n同步标签门控，忙时跳过整帧')
block('sample',XS[3],UP,4.35,'8 倍最近邻降采样',
      'x = 0, 8, …, 1272；y = 0, 8, …, 712\n输出 160 × 90 = 14,400 个 RGB 像素')
for i in range(3):
    arrow('video_step_'+str(i),[(XS[i]+2.175,UP),(XS[i+1]-2.175,UP)])

block('metadata',14.35,8.6,4.35,'帧元数据 CDC 握手',
      '33 位信息独立保持 / 应答\n与对应 START token 绑定',h=1.0)
block('fifo',19.75,8.6,4.35,'Token 异步 FIFO',
      '256 × 26 位：2 位类型 + 24 位 RGB\nSTART / SAMPLE / END',h=1.0)
arrow('sample_fifo',[(19.75,10.56),(19.75,9.1)])
arrow('metadata_cdc',[(14.35,10.56),(14.35,9.1)],True)
label('fifo_clock',22.8,8.6,1.35,.7,'Gray 指针\n双级同步',11)

LOW=5.65
block('clear',19.75,LOW,4.35,'帧开始与清零等待',
      '触发打包器清零 PING 的 3,600 个字\n清零期间暂不输出 RGB 字节')
block('serialize',14.35,LOW,4.35,'RGB 像素拆字节',
      'R → G → B，8 位字节流\nframe_valid / byte_valid / byte')
block('packer',8.95,LOW,4.35,'CHW 映射与 128 位打包',
      '每 16 个像素，分别提交 R / G / B 整字\n有效区字基址：150 / 1350 / 2550')
block('ping',3.55,LOW,4.35,'PING 输入特征缓存',
      'R 平面 → G 平面 → B 平面\n160 × 120 × 3 = 57,600 字节')
arrow('fifo_clear',[(19.75,8.1),(19.75,6.29)])
for i in [3,2,1]:
    arrow('npu_step_'+str(i),[(XS[i]-2.175,LOW),(XS[i-1]+2.175,LOW)])
arrow('meta_bind',[(14.35,8.1),(14.35,7.8),(22.55,7.8),(22.55,5.65),(21.925,5.65)],True)
label('meta_label',18.35,7.99,4.0,.28,'帧号与像素流保持对应',11)
arrow('clear_control',[(19.75,6.29),(19.75,7.08),(8.95,7.08),(8.95,6.29)],True)
label('clear_control_label',10.55,7.27,3.2,.25,'帧开始：打包器先清零',11)
label('module_video',8.1,10.16,9.8,.26,'npu_video_input → npu_rgb_input（视频侧）',11)
label('module_npu',12.2,4.43,21,.3,
      'npu_rgb_input（NPU 侧：FIFO 读取 / 字节输出） → lbp_to_ping_packer（STREAMED_RGB=1） → fm_bank_array',11)

# Explicit tensor illustration: zeros are created in PING, not by an extra scaler.
shape('letterbox',2.8,2.05,2.8,1.55,fill='paper')
shape('top_padding',2.8,2.72,2.8,.2,'15 行黑边',fill='black',stroke=None,size=10,color='paper')
shape('active_image',2.8,2.05,2.8,1.15,'160 × 90\n有效 RGB 图像',size=15,bold=True)
shape('bottom_padding',2.8,1.38,2.8,.2,'15 行黑边',fill='black',stroke=None,size=10,color='paper')
label('letterbox_dimension',2.8,1.01,3.4,.25,'最终尺寸：160 × 120',12)
for i,(name,base) in enumerate([('R',0),('G',1200),('B',2400)]):
    x=5.8+i*2.03
    shape('plane_'+name,x,2.05,1.68,1.45,
          name+' 平面\n1,200 字\n起址 '+str(base),size=13)
label('word_note',7.83,1.01,6.0,.25,'字地址单位：128 位；上下黑边在各通道内保留',11)

block('complete',18.2,2.28,9.7,'有效帧完整性检查',
      '真实 END token + 14,400 个采样点 + 最后一个完整字提交\n确认 preload_done 后，交给 NPU 第 0 层推理',h=1.22)
arrow('ping_complete',[(3.55,5.01),(3.55,3.86),(23.55,3.86),(23.55,2.28),(23.05,2.28)])
label('complete_note',18.2,1.19,9.8,.55,
      'FIFO 满时中止采集；异常帧不触发本次预装载完成。\n当前路径保持 RGB 数据，不经过灰度 / LBP。',12)
label('footer',12.2,.3,23,.3,
      '依据当前人员模型预处理 RTL 整理；实线为数据 / 提交路径，虚线为控制与元数据。未运行新的综合或实板测试。',11)
for p in panels:
    p.SendToBack()

checks={
    'npu_rgb_input.v':['reg [25:0] token_mem [0:255]','target_x={dx_reg,3\'b000}',
                       'target_y={dy_reg,3\'b000}','n_sample_count==14400','TOK_END'],
    'lbp_to_ping_packer.v':['r_clear_addr==3599','12\'d150','12\'d1350','12\'d2550',
                          'o_preload_wr_mask<=16\'hffff','r_stream_complete'],
    'npu_video_input.v':['video_valid_reg[1]','i_frame_metadata_valid','sync_gate'],
    'npu_top_with_sdram_dma.v':['localparam STREAMED_RGB_INPUT = 1','w_preload_done']}
for name,tokens in checks.items():
    s=(RTL/name).read_text(encoding='utf-8-sig')
    assert all(t in s for t in tokens),(name,tokens)
assert 1280//8==160 and 720//8==90
assert (120-90)//2==15
assert 160*120*3==3600*16==57600
assert [15*160//16+i*1200 for i in range(3)]==[150,1350,2550]
base=OUT/'NPU预处理架构图_蓝橙配色'
doc.SaveAs(str(base.with_suffix('.vsdx')))
app.Settings.SetRasterExportResolution(0,135,135,0)
for ext in ['.png','.svg']:
    page.Export(str(base.with_suffix(ext)))
with zipfile.ZipFile(base.with_suffix('.vsdx')) as z:
    assert z.testzip() is None
    xml=z.read('visio/pages/page1.xml').decode('utf-8')
    assert all(t in xml for t in ['14,400','57,600','CHW','256 × 26'])
audit={'source_sha256':{str(RTL/f):hashlib.sha256((RTL/f).read_bytes()).hexdigest() for f in checks},
       'source_and_geometry_checks':'PASS','tensor_layout_arithmetic':'PASS','vsdx_package_check':'PASS'}
(OUT/'NPU预处理架构图_来源核对.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8')
app.Visible=True
app.ActiveWindow.ViewFit=1
print('PASS: native Visio NPU preprocessing diagram and PNG/SVG saved')
