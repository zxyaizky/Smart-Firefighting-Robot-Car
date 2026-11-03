"""Current A-board NPU architecture, with code-checked modules and native Visio shapes."""
from pathlib import Path
import ast
import hashlib
import json
import zipfile
import win32com.client

OUT=Path(__file__).resolve().parent
ROOT=OUT.parent
A=ROOT/'lab_ex3_osd_SC500_720/lab_ex3_osd'
RTL=A/'td_project/import'
W,H=24.3,16.0
C={'navy':'RGB(0,0,0)','blue':'RGB(0,0,0)','ink':'RGB(0,0,0)',
   'muted':'RGB(60,60,60)','border':'RGB(50,50,50)',
   'light':'RGB(203,229,254)','panel':'RGB(203,229,254)',
   'white':'RGB(255,203,153)','paper':'RGB(255,255,255)'}
app=win32com.client.GetActiveObject('Visio.Application')
doc=app.Documents.Add('')
page=doc.Pages.Item(1)
page.Name='NPU总体架构图'
for k,v in [('PageWidth',W),('PageHeight',H),('DrawingScale',1),('PageScale',1)]:
    page.PageSheet.CellsU(k).FormulaU=f'{v} in'
nodes,lines,panels={},[],[]
helper=OUT/'draw_blue_design_flow.py'
tree=ast.parse(helper.read_text(encoding='utf-8'))
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef)],
                        type_ignores=[]),str(helper),'exec'))


def block(key,x,y,w,h,title,detail='',size=16,external=False):
    s=shape(key,x,y,w,h,fill='paper' if external else 'white',size=size)
    if detail:
        label(key+'_title',x,y+.19,w-.18,.38,title,size,'ink',True)
        label(key+'_detail',x,y-.25,w-.18,.52,detail,12,'muted')
    else:
        s.Text=title
        setc(s,'Char.Style',1)
    return s


def tag(key,x,y,w,content,size=11):
    return label(key,x,y,w,.3,content,size,'ink')


label('title',12.15,15.35,23,.65,'NPU 总体架构图',29,'ink',True)
label('subtitle',12.15,14.77,22.8,.34,
      'A 板人员检测  ·  描述符驱动的硬件推理  ·  8 位特征 / 权重，32 位累加',14)
for key,x,y,w,h,title in [
    ('inputs_panel',3.3,8.15,5.5,12.15,'输入与参数存储'),
    ('core_panel',13.25,8.15,12.5,12.15,'NPU 推理核心  ·  npu_network_top'),
    ('results_panel',21.9,8.15,3.6,12.15,'检测结果与应用')]:
    panels.append(shape(key,x,y,w,h,fill='panel'))
    label(key+'_title',x,13.83,w-.25,.4,title,18,'ink',True)

# Board-level input and parameter transport.
block('video',3.3,12.7,4.8,.88,'摄像头 / ISP / 视频 DDR','1280 × 720 RGB888，OSD 前取流',external=True)
block('input',3.3,11.15,4.8,1.12,'图像采样与跨时钟输入','160 × 90 采样；按 160 × 120 补零布局\nnpu_video_input / npu_rgb_input')
block('flash',3.3,9.25,4.8,.88,'U33 Flash 模型参数','当前人员模型参数与 MCU 启动固件',external=True)
block('load',3.3,7.7,4.8,1.0,'MCU / AHB 桥与参数装载','npu_u33_mcu_bridge / npu_param_loader')
block('ddr',3.3,6.05,4.8,1.12,'共享 DDR 控制与调度','视频与参数分区；参数写入 / 回读校验\nnpu_ddr_scheduler')
block('bridge',3.3,4.35,4.8,1.0,'NPU 参数读桥 / CDC','DDR 128 位数据 → NPU 16 位读流\nnpu_ddr_read_bridge')
label('ready_note',3.3,2.8,4.8,.65,'启动条件：参数校验通过且模型就绪\n忙时整帧拒绝，保持原视频通路独立',12)
arrow('video_input',[(3.3,12.26),(3.3,11.71)])
arrow('flash_load',[(3.3,8.81),(3.3,8.2)])
arrow('load_ddr',[(3.3,7.2),(3.3,6.61)])
arrow('ddr_read_bridge',[(3.3,5.49),(3.3,4.85)])

# Configuration/control plane: descriptor RAM, sequencer, address/tile control.
block('descriptor',9.1,12.55,3.3,1.0,'模型描述符 ROM / RAM','当前 12 层网络配置\nnpu_model_config.vh',size=15)
block('sequencer',13.35,12.55,3.8,1.0,'层序 / Tile 控制器','层配置、参数请求与完成判断\nnpu_sequencer',size=16)
block('bcu',17.55,12.55,2.65,1.0,'访存控制 BCU','地址、读写与层切换\nbcu',size=15)
arrow('descriptor_seq',[(10.75,12.55),(11.45,12.55)])
arrow('seq_bcu',[(15.25,12.55),(16.225,12.55)],True)
tag('descriptor_bus',11.1,12.94,1.2,'层描述符')
tag('seq_bcu_bus',15.73,12.94,.95,'配置',10)

# Feature memory and input packer; RGB bytes are packed into CHW PING layout.
block('packer',9.0,10.8,2.9,1.05,'输入打包 / 预装载','RGB 字节流 → CHW\nlbp_to_ping_packer',size=14)
block('features',14.8,10.8,7.4,1.05,'PING / PONG 特征缓存','片上分 Bank RAM；层间交替读写 / 128 位结果写回\nfm_bank_array',size=17)
arrow('sample_preload',[(5.7,11.15),(6.65,11.15),(6.65,10.8),(7.55,10.8)])
tag('byte_stream',6.65,11.55,1.7,'RGB8 / valid',11)
arrow('preload_ping',[(10.45,10.8),(11.1,10.8)])
arrow('bcu_feature_ctrl',[(17.55,12.05),(17.55,11.325)],True)
tag('bcu_ctrl_label',18.55,11.7,1.65,'地址 / 读写控制',11)

# Compute pipeline. Physical lane count follows pe_array, rather than its name.
block('window',9.1,7.65,3.3,1.22,'窗口生成 / Padding','1 × 1 / 3 × 3 卷积窗口\nline_buffer_conv',size=15)
block('mac',13.35,7.65,3.8,1.22,'卷积 PE / 部分和累加','2 组物理 MAC 树，分时复用 16 通道\npe_array / channel_accumulator',size=16)
block('activation',17.55,7.65,2.8,1.22,'偏置 / 激活 / 量化','融合两通道处理\nactivation_quant_fused',size=14)
arrow('feature_read',[(12.1,10.275),(12.1,9.7),(9.1,9.7),(9.1,8.26)])
tag('feature_stream',10.0,9.95,3.0,'8 位特征读取 / valid',11)
arrow('window_mac',[(10.75,7.65),(11.45,7.65)])
arrow('mac_quant',[(15.25,7.65),(16.15,7.65)])
tag('mac_quant_label',15.7,8.05,1.3,'32 位累加',11)

block('pool',17.55,5.55,2.8,1.05,'池化 / 旁路','按层配置启用；输出重排\npool_reorder / line_buffer_pool',size=14)
block('writeback',13.35,5.55,3.8,1.05,'结果写回与层间复用','128 位特征向量 → PING / PONG',size=16)
arrow('quant_pool',[(17.55,7.04),(17.55,6.075)])
arrow('pool_writeback',[(16.15,5.55),(15.25,5.55)])
arrow('writeback_loop',[(15.25,5.55),(15.7,5.55),(15.7,10.0),(14.8,10.0),(14.8,10.275)])
tag('feedback_label',15.94,9.35,2.7,'层间特征写回',11)

# Parameter DMA and on-chip parameter buffers.
block('dma',9.1,4.15,3.3,1.05,'权重 / 偏置 DMA','按层请求、打包与更新\nweight_sdram_dma',size=15)
block('weights',9.1,5.8,3.3,.92,'片上权重 / 偏置缓存','weight_buffer / bias_buffer',size=15)
arrow('bridge_dma',[(5.7,4.35),(6.65,4.35),(6.65,4.15),(7.45,4.15)])
arrow('dma_buffer',[(9.1,4.675),(9.1,5.34)])
arrow('weights_pe',[(10.75,5.8),(11.0,5.8),(11.0,7.3),(11.45,7.3)])
arrow('bias_activation',[(10.75,6.0),(11.17,6.0),(11.17,6.6),(17.0,6.6),(17.0,7.04)])
tag('bias_label',13.3,6.8,2.2,'32 位 Bias',11)
arrow('seq_dma_request',[(11.45,12.3),(11.0,12.3),(11.0,11.7),(7.2,11.7),(7.2,3.2),(9.1,3.2),(9.1,3.625)],True)
tag('dma_control_label',8.3,3.0,2.7,'DMA req / ack / done',11)

# The winner reduction lives in the sequencer; depict its functional result stage.
block('reduce',13.35,3.6,3.8,1.0,'末层网格最大置信度归约','20 × 15 × 6 → 单目标结果\n归约逻辑位于 npu_sequencer',size=15)
arrow('last_layer_reduce',[(13.35,5.025),(13.35,4.1)])
tag('last_layer_label',14.55,4.55,2.0,'仅末层结果',11)

block('decode',21.9,9.45,3.15,1.22,'检测结果解码','置信度 / 框坐标\n关联来源帧号',size=16)
block('hdmi',21.9,12.0,3.15,1.0,'本地 HDMI / OSD','人员检测显示',size=16,external=True)
block('udp',21.9,6.75,3.15,1.1,'UDP 元数据输出','人员框 + 帧号 → B 板',size=15,external=True)
block('voice',21.9,4.2,3.15,1.0,'语音触发输出','本地 UART 提示',size=16,external=True)
arrow('result_decode',[(15.25,3.6),(19.8,3.6),(19.8,9.45),(20.325,9.45)])
tag('tensor_label',17.3,3.9,3.1,'64 位结果 / inference_done',11)
arrow('decode_display',[(21.9,10.06),(21.9,11.5)])
arrow('decode_udp',[(21.9,8.84),(21.9,7.3)])
arrow('result_voice',[(19.8,4.2),(20.325,4.2)])
tag('bbox_module',21.9,7.93,3.1,'npu_bbox_overlay_160x120',10)

label('legend',12.15,1.45,23,.4,'实线：特征 / 参数 / 结果数据流      虚线：层配置、访存与 DMA 控制',13,'ink')
label('footer',12.15,.8,23,.48,
      '依据当前 A 板 RTL 整理；历史 lbp 命名接口在本路径承载 RGB 数据。图中采用功能分组，非资源或实板性能验收图。',11)
for p in panels:
    p.SendToBack()

files=['npu_network_top.v','npu_top_with_sdram_dma.v','npu_core_top.v','npu_sequencer.v',
       'conv_engine_top.v','pe_array.v','npu_model_config.vh','npu_video_input.v',
       'npu_rgb_input.v','lbp_to_ping_packer.v','npu_ddr_subsystem.v',
       'weight_sdram_dma.v','npu_bbox_overlay_160x120.v']
checks={'npu_network_top.v':['.USE_DESC_RAM(1\'b1)','u_npu'],
        'npu_core_top.v':['u_sequencer','u_bcu','u_ping_array','u_pong_array','u_conv_engine'],
        'pe_array.v':['localparam PHYSICAL_LANES = 2'],
        'npu_model_config.vh':['MODEL_LAYER_COUNT = 12'],
        'npu_sequencer.v':['r_grid_best_conf','r_reduce_max_grid'],
        'conv_engine_top.v':['u_weight_buf','u_bias_buf','u_activation_quant','u_lb_pool']}
for name,tokens in checks.items():
    source=(RTL/name).read_text(encoding='utf-8-sig')
    assert all(t in source for t in tokens),(name,tokens)
base=OUT/'NPU总体架构图_蓝橙配色'
doc.SaveAs(str(base.with_suffix('.vsdx')))
app.Settings.SetRasterExportResolution(0,135,135,0)
for ext in ['.png','.svg']:
    page.Export(str(base.with_suffix(ext)))
with zipfile.ZipFile(base.with_suffix('.vsdx')) as z:
    assert z.testzip() is None
    content=z.read('visio/pages/page1.xml').decode('utf-8')
    assert all(t in content for t in ['PING / PONG','物理 MAC','最大置信度归约','U33 Flash'])
audit={'file':str(base.with_suffix('.vsdx')),'shape_count':page.Shapes.Count,
       'source_sha256':{str(RTL/f):hashlib.sha256((RTL/f).read_bytes()).hexdigest() for f in files},
       'source_instance_checks':'PASS','vsdx_package_check':'PASS',
       'scope':'Architecture drawing only; no RTL modification, synthesis or board tests'}
(OUT/'NPU总体架构图_来源核对.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8')
app.Visible=True
app.ActiveWindow.ViewFit=1
print(json.dumps({'path':str(base.with_suffix('.vsdx')),'check':'PASS'},ensure_ascii=False))
