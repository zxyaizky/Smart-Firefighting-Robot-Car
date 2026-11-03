import json
from pathlib import Path

OUT = Path(__file__).parent
BLUE, ORANGE, INK = '#CBE5FE', '#FFCB99', '#202020'
plan = {'page': {'name': '网络调度与权重参数加载', 'width': 24, 'height': 17.5},
        'shapes': [], 'connectors': []}


def box(sid, x, y, w, h, title='', lines=(), fill=ORANGE, intent='module'):
    obj = dict(id=sid, kind='rounded-rectangle', shapeIntent=intent,
               preferredSource='stencil', stencil='BASIC_M.VSSX', master='Rounded Rectangle',
               x=x, y=y, width=w, height=h, fill=fill, line=INK,
               lineWeight=1, fontColor='#000000', fontFamily='SimSun', fontSize=18)
    if title:
        spans = [{'text': title, 'fontFamily': 'SimSun', 'fontSize': 22}]
        for line in lines:
            spans.append({'text': '\n' + line, 'fontFamily': 'SimSun', 'fontSize': 17})
        obj['richText'] = spans
        obj['text'] = title + '\n' + '\n'.join(lines)
    plan['shapes'].append(obj)


def text(sid, x, y, w, h, value, size=15, bold=False):
    plan['shapes'].append(dict(id=sid, kind='text', shapeIntent='caption',
        preferredSource='primitive', x=x, y=y, width=w, height=h, text=value,
        fontFamily='SimSun', fontSize=size, fontColor='#000000', bold=bold))


def edge(sid, source, target, fp=(1,.5), tp=(0,.5), control=False):
    shapes = {s['id']: s for s in plan['shapes']}
    def pos(s, p):
        return [s['x'] + (p[0]-.5)*s['width'], s['y'] + (p[1]-.5)*s['height']]
    start, end = pos(shapes[source],fp), pos(shapes[target],tp)
    plan['connectors'].append(dict(id=sid, **{'from':source, 'to':target},
        kind='dynamic', fromX=fp[0], fromY=fp[1], toX=tp[0], toY=tp[1],
        arrow=True, line=INK, lineWeight=1.3, dashed=control,
        points=start+end, text=''))


box('boot_region',12,13.65,22.3,3.2,fill=BLUE,intent='container')
box('schedule_region',6.1,6.65,10.5,9.6,fill=BLUE,intent='container')
box('runtime_region',17.55,6.65,11.2,9.6,fill=BLUE,intent='container')
text('title',12,16.55,22,.7,'NPU 网络调度与权重参数加载',36,True)
text('subtitle',12,15.85,22,.4,'Flash 参数装载  ·  描述符驱动层调度  ·  DDR 权重 / 偏置按需供给',17)
text('boot_title',12,14.86,20,.42,'① 启动参数装载与校验',23,True)
text('schedule_title',6.1,10.95,9.8,.45,'② 网络层序与分组调度',23,True)
text('runtime_title',15.65,10.95,6.5,.45,'③ 运行期参数读取与供给',23,True)

box('flash',3.4,13.3,4.2,1.8,'U33 Flash 模型参数',
    ['人员模型权重 / 偏置','参数镜像：327680 字节'],fill='#FFFFFF')
box('ahb',8.3,13.3,4.2,1.8,'MCU / AHB 参数桥',
    ['32 位写入 → 128 位打包','跨时钟 FIFO','npu_u33_mcu_bridge'])
box('loader',13.5,13.3,4.7,1.8,'参数装载与读回校验',
    ['暂停推理 → 写入 → CRC32','通过置 params_ready；失败拦截','npu_param_loader'])
box('ddr',19.3,13.3,5.4,1.8,'共享 DDR 参数分区',
    ['视频与参数分区存储','128 位数据读写','npu_ddr_scheduler'])

box('desc',3.45,9.5,4.4,1.7,'模型描述符 ROM / RAM',
    ['当前 12 层；启动写入描述符','npu_model_config.vh'])
box('sequencer',8.6,9.5,4.8,1.7,'层描述符读取与解析',
    ['卷积 / 池化 / 量化及参数地址','npu_sequencer'])
box('admit',3.45,6.9,4.4,1.7,'模型就绪与帧接纳',
    ['参数校验 + 描述符就绪','空闲时接收；输入预装载完成'],fill='#FFFFFF')
box('iterate',8.6,6.9,4.8,1.7,'层 / Tile / 通道分组',
    ['计算地址、长度与分组边界','等待 DMA 完成后启动计算','npu_sequencer'])
box('core',8.6,3.9,4.8,1.8,'计算核心与完成反馈',
    ['BCU / conv_engine_top','完成当前 Cin 分组与 Tile','tile_error 阻止继续推进'])
box('done',3.45,3.9,4.4,1.8,'下一层 / 推理完成',
    ['本层结束：读取下一层描述符','末层结束：inference_done'],fill='#FFFFFF')

box('bridge',19.3,9.5,6.1,1.7,'DDR 读桥与跨时钟',
    ['请求范围校验；DDR 128 位 → NPU 16 位','npu_ddr_read_bridge'])
box('dma',19.3,6.9,6.1,1.7,'权重 / 偏置 DMA',
    ['32 位参数字 → 每次读取 2 个 16 位半字','先提交权重，再读取并提交偏置','weight_sdram_dma'])
box('cache',19.3,3.9,6.1,1.8,'片上权重与偏置缓存',
    ['144 位权重：2 × 9 × 8 bit','32 位 Bias；按 OC 组更新','weight_buffer / bias_buffer'])

text('priority_note',14.1,9.5,3.6,1.55,
     'DDR 仲裁顺序\n视频 → 参数装载 → NPU\n由 npu_ddr_scheduler 仲裁',15)
text('schedule_note',6.1,2.35,9.8,.6,
     '循环推进：Cin 分组 → 空间 Tile → OC 分组 → 下一层',16)
text('reuse_note',17.55,2.35,10.4,.6,
     '单 Cin 组层可跨 Tile 复用参数，跳过重复 DMA 读取',16)
text('legend',12,1.05,22,.45,
     '实线：参数 / 计算数据流     虚线：调度与握手     |     依据当前 A 板 RTL 绘制',16)

edge('flash_to_ahb','flash','ahb')
edge('ahb_to_loader','ahb','loader')
edge('load_write','loader','ddr',(1,.72),(0,.72))
edge('load_readback','ddr','loader',(0,.25),(1,.25))
edge('ddr_to_bridge','ddr','bridge',(.5,0),(.5,1))
edge('bridge_read_request','bridge','ddr',(.8,1),(.8,0),True)
edge('desc_to_decode','desc','sequencer')
edge('desc_ready','desc','admit',(.5,0),(.5,1),True)
edge('decode_to_iterate','sequencer','iterate',(.5,0),(.5,1),True)
edge('frame_to_iterate','admit','iterate',(1,.5),(0,.5),True)
edge('dma_req','iterate','dma',(1,.73),(0,.73),True)
edge('dma_done','dma','iterate',(0,.23),(1,.23),True)
edge('read_stream','bridge','dma',(.29,0),(.29,1))
edge('read_request','dma','bridge',(.73,1),(.73,0),True)
edge('commit_to_cache','dma','cache',(.5,0),(.5,1))
edge('cache_to_core','cache','core',(0,.5),(1,.5))
edge('layer_start','iterate','core',(.72,0),(.72,1),True)
edge('layer_feedback','core','iterate',(.25,1),(.25,0),True)
edge('core_to_done','core','done',(0,.5),(1,.5),True)

text('desc_label',6.03,9.88,1.02,.3,'层配置',13)
text('desc_ready_label',4.68,8.15,2.1,.3,'model_ready',13)
text('req_label',13.65,7.65,4.5,.35,'dma_req / base_addr / length',15)
text('done_label',13.65,6.03,4.5,.35,'dma_ack / dma_done',15)
text('ddr_stream_label',17.85,11.83,2.5,.3,'128 位读返回',14)
text('ddr_req_label',22.1,11.83,1.6,.3,'读请求',14)
text('stream_label',16.6,8.19,2.3,.35,'16 位数据流',14)
text('read_req_label',21.95,8.19,2.25,.35,'req / ready',14)
text('commit_label',21,5.35,3,.4,'权重 / 偏置写入与更新',14)
text('cache_label',13.7,4.3,4.5,.35,'144 位权重 / 32 位偏置',15)
text('start_label',10.65,5.35,1.55,.32,'layer_start',13)
text('feedback_label',6.5,5.35,1.4,.32,'layer_done',13)

path=OUT/'NPU网络调度与权重参数加载_绘图计划.json'
path.write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
print(path)
print(f"{len(plan['shapes'])} shapes, {len(plan['connectors'])} native dynamic connectors")
