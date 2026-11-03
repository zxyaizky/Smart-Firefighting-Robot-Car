"""Eight code-grounded algorithm flowcharts, one page per requested subject."""
from pathlib import Path
import json

ROOT=Path(__file__).parent
BLUE,ORANGE,WHITE,INK='#CBE5FE','#FFCB99','#FFFFFF','#202020'
PAGES=[]

class Flow:
    def __init__(self,num,name,rows=10,height=None):
        self.num,self.name,self.w=num,name,22
        self.h=height or 5+1.9*(rows-1)
        self.nodes=[];self.labels=[];self.edges=[]
        self.box('region',11,(self.h-1.15)/2,20.3,self.h-2.85,'',BLUE,container=True)
        self.label('title',11,self.h-1.15,20,.6,f'{num:02d}  {name}流程图',27)

    def y(self,row):return self.h-3.1-1.9*row

    def box(self,sid,x,y,w,h,text,fill=ORANGE,shape='roundrect',size=18,container=False):
        n=dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,shape=shape,
               fill=fill,line=INK,fontName='Microsoft YaHei',fontSize=size,container=container)
        self.nodes.append(n)
        return sid

    def step(self,sid,row,text,kind='process',side=None):
        x=3.7 if side=='left' else 18.3 if side=='right' else 11
        w=4.3 if side else 6.8
        h=1.15
        fill=ORANGE
        shape='roundrect'
        if kind in ['start','end']:
            w,h,fill,shape=4.5,.85,WHITE,'ellipse'
        elif kind=='decision':
            w,h,fill,shape=6,1.45,WHITE,'diamond'
        return self.box(sid,x,self.y(row),w,h,text,fill,shape,16.5 if side or kind=='decision' else 18)

    def label(self,sid,x,y,w,h,text,size=14):
        self.labels.append(dict(id=sid,x=x-w/2,y=y-h/2,w=w,h=h,text=text,
            fontName='Microsoft YaHei',fontSize=size))

    def edge(self,a,b,fp=(.5,0),tp=(.5,1),label='',corners=None,dashed=False):
        lookup={n['id']:n for n in self.nodes}
        def point(n,p):return [n['x']+p[0]*n['w'],n['y']+p[1]*n['h']]
        s,e=point(lookup[a],fp),point(lookup[b],tp)
        if corners is None:
            corners=[]
            if abs(s[0]-e[0])>1e-7 and abs(s[1]-e[1])>1e-7:
                corners=[(e[0],s[1])] if fp[0] in [0,1] else [(s[0],e[1])]
        sid=f'edge_{len(self.edges)+1:02d}_{a}_{b}'
        self.edges.append(dict(id=sid,**{'from':a,'to':b},fromX=fp[0],fromY=fp[1],
            toX=tp[0],toY=tp[1],points=s+[v for xy in corners for v in xy]+e,
            kind='dynamic',line=INK,lineWeight=.75,endArrow=4,text='',dashed=dashed))
        if label:
            if fp[0] in [0,1]:
                x=s[0]+(.85 if fp[0] else -.85);y=s[1]+.32
            else:
                x=s[0]+.9;y=s[1]-.36
            self.label(sid+'_label',x,y,1.1,.32,label,14)

    def chain(self,*ids):
        for a,b in zip(ids,ids[1:]):self.edge(a,b)

    def finish(self,source):
        self.label('source',11,1.12,19.5,.32,source,11.5)
        self.page=dict(name=f'{self.num:02d}_{self.name}',pageWidth=self.w,pageHeight=self.h,
            nodes=self.nodes,labels=self.labels,connections=self.edges)
        PAGES.append(self.page)
        return self


f=Flow(1,'灰度化与图像滤波',10)
f.step('start',0,'开始',kind='start')
f.step('input',1,'输入 RGB888 与有效控制信号\n按 DE 处理有效像素')
f.step('weight',2,'计算固定系数乘积\nR × 77，G × 150，B × 29')
f.step('gray',3,'灰度 Y = (77R + 150G + 29B) >> 8\nRGB 与 HS / VS / DE 同步延迟 3 拍')
f.step('window',4,'行缓存生成 3 × 3 灰度窗口\n边界与行间消隐按窗口模块处理')
f.step('sort',5,'分别对三行像素排序\n每行得到最小值、中值、最大值')
f.step('candidate',6,'计算三个候选值\n行最小值的最大、行中值的中值、行最大值的最小')
f.step('median',7,'对三个候选值再取中值\n得到九个邻域像素的中位数')
f.step('output',8,'输出中值灰度与同步后的控制信号\n灰度显示时 R = G = B = Ymed')
f.step('end',9,'结束（当前像素输出）',kind='end')
f.chain('start','input','weight','gray','window','sort','candidate','median','output','end')
f.finish('对应：rgb2ycbcr.v、VIP_Gray_Median_Filter_720p.v；灰度中值是 Sobel 的前级。')

f=Flow(2,'SOBEL边缘检测',10)
for sid,row,text,kind in [
    ('start',0,'开始','start'),('input',1,'输入原始亮度 Y\n先执行 3 × 3 灰度中值去噪','process'),
    ('window',2,'生成中值图像的 3 × 3 邻域\n读取上下左右加权像素','process'),
    ('grad',3,'Sobel 卷积计算 Gx、Gy\nGx = 右列加权和 − 左列加权和\nGy = 下行加权和 − 上行加权和','process'),
    ('mag',4,'幅值 M = |Gx| + |Gy|\n按水平、垂直、两条对角线划分方向','process'),
    ('neighbors',5,'生成梯度邻域\n沿梯度方向取前邻与后邻幅值','process'),
    ('keep',6,'M ≥ 60，且 M > 前邻\n且 M ≥ 后邻？','decision'),
    ('yes',7,'保留边缘\n边缘位 = 1，输出白色','process'),
    ('out',8,'输出细边缘 RGB888\n白色边缘、黑色背景；同步 VS / DE','process'),
    ('end',9,'结束（当前像素输出）','end')]:f.step(sid,row,text,kind)
f.step('no',7,'抑制非边缘\n边缘位 = 0，输出黑色',side='right')
f.chain('start','input','window','grad','mag','neighbors','keep')
f.edge('keep','yes',label='是');f.edge('keep','no',(1,.5),(.5,1),label='否')
f.edge('yes','out');f.edge('no','out',(.5,0),(1,.5));f.edge('out','end')
f.finish('对应：Sobel_Edge_Detector.v；当前实例阈值 60，NMS_ENABLE = 1，采用 L1 梯度幅值。')

f=Flow(3,'直方图均衡化与图像增强',10)
for sid,row,text,kind in [
    ('start',0,'开始','start'),('clear',1,'初始化 256 级直方图\n清零统计；LUT 有效标志置 0','process'),
    ('collect',2,'输入有效灰度 Y，累加 Hist[Y]\n相同灰度连续写入使用旁路递增','process'),
    ('valid',3,'已有可用映射表？','decision'),('map',4,'输出增强灰度 LUT[Y]\n使用先前一帧生成的映射','process'),
    ('boundary',5,'到达帧边界？','decision'),('cdf',6,'垂直消隐期间扫描 0…255\nCDF(k) = Σ Hist[0…k]','process'),
    ('lut',7,'LUT[k] = min(255, (CDF × 74275) >> 28)\n生成新映射，同时清零已扫描直方图','process'),
    ('ready',8,'映射表置为有效\n回到统计状态，供后续帧查表','process'),('end',9,'结束（本轮映射更新）','end')]:f.step(sid,row,text,kind)
f.step('raw',4,'尚无映射表\n输出原始灰度',side='right')
f.step('continue',5,'继续处理本帧\n等待帧边界',side='left')
f.chain('start','clear','collect','valid')
f.edge('valid','map',label='是');f.edge('valid','raw',(1,.5),(.5,1),label='否')
f.edge('map','boundary');f.edge('raw','boundary',(.5,0),(1,.5))
f.edge('boundary','cdf',label='是');f.edge('boundary','continue',(0,.5),(1,.5),label='否')
f.edge('continue','collect',(.5,1),(0,.5));f.chain('cdf','lut','ready','end')
f.finish('对应：histogram_equalizer_720p.v；1280 × 720、256 bins、前帧 LUT，首帧直通。')

f=Flow(4,'图像卡通化处理',11)
for sid,row,text,kind in [
    ('start',0,'开始','start'),('align',1,'输入 RGB888\n原始 RGB 延迟 3 拍，与 YCbCr 控制对齐','process'),
    ('median',2,'RGB 三通道 3 × 3 中值滤波\n共享窗口控制，各通道独立取中值','process'),
    ('lift',3,'分段提亮暗部\nx < 64：x + x/2\n64 ≤ x < 128：x + (128−x)/2','process'),
    ('sat',4,'估计亮度 Y ≈ (R + 2G + B + 2) >> 2\n绕中性亮度增强饱和度至 1.25 倍并限幅','process'),
    ('quant',5,'各通道量化为六个色阶\n0、36、96、168、219、255','process'),
    ('gradient',6,'亮度窗口计算 Sobel 型梯度\n判断中心是否位于轮廓暗侧','process'),
    ('outline',7,'轮廓启用、梯度 ≥ 180\n且中心亮度低于邻域均值？','decision'),
    ('dark',8,'量化 RGB 各通道右移 2 位\n形成深色轮廓','process'),
    ('out',9,'色块与轮廓结果合成\n同步输出 RGB888、VS、DE','process'),('end',10,'结束（当前像素输出）','end')]:f.step(sid,row,text,kind)
f.step('plain',8,'保留量化 RGB\n形成平坦色块',side='right')
f.chain('start','align','median','lift','sat','quant','gradient','outline')
f.edge('outline','dark',label='是');f.edge('outline','plain',(1,.5),(.5,1),label='否')
f.edge('dark','out');f.edge('plain','out',(.5,0),(1,.5));f.edge('out','end')
f.finish('对应：当前正式登记的 rtl/rescue/rgb_quantize_4.v；六级量化、暗部提亮、强轮廓描边。')

f=Flow(5,'运动目标检测',11)
for sid,row,text,kind in [
    ('start',0,'开始','start'),('block',1,'输入亮度 Y，按 8 × 8 块累加\n块均值 = 块总和 >> 6，得到 160 × 90 网格','process'),
    ('history',2,'读取同一块的上一帧均值\n与当前块均值配对','process'),
    ('valid',3,'历史有效\n且不在屏蔽的 OSD 区域？','decision'),
    ('diff',4,'|当前均值 − 上帧均值| ≥ 12？','decision'),
    ('motion',5,'运动掩码置 1，块计数加 1\n更新运动块最小 / 最大坐标','process'),
    ('store',6,'把当前均值与运动掩码写入历史 RAM\n按块继续，直至一帧统计完成','process'),
    ('enough',7,'帧边界：有有效运动坐标\n且运动块数量 ≥ 12？','decision'),
    ('active',8,'锁存 motion_active = 1\n计数与结果在下一帧保持稳定','process'),
    ('out',9,'输出稳定的运动区域图与二值帧差图\n有效运动块橙色高亮；帧差按掩码显黑白','process'),
    ('end',10,'结束（本帧检测）','end')]:f.step(sid,row,text,kind)
f.step('static',5,'运动掩码置 0\n不累计运动块',side='right')
f.step('inactive',8,'锁存 motion_active = 0\n运动区域图保留灰度',side='right')
f.chain('start','block','history','valid')
f.edge('valid','diff',label='是')
f.edge('valid','static',(1,.5),(1,.5),label='否',
    corners=[(20.8,f.y(3)),(20.8,f.y(5))])
f.edge('diff','motion',label='是');f.edge('diff','static',(1,.5),(.5,1),label='否')
f.edge('motion','store');f.edge('static','store',(.5,0),(1,.5));f.edge('store','enough')
f.edge('enough','active',label='是');f.edge('enough','inactive',(1,.5),(.5,1),label='否')
f.edge('active','out');f.edge('inactive','out',(.5,0),(1,.5));f.edge('out','end')
f.finish('对应：motion_frame_diff.v；块均值历史和掩码用片上 RAM，结果延后一帧显示。')

f=Flow(6,'实时显示与数据分流',11)
for sid,row,text,kind in [
    ('start',0,'开始','start'),('capture',1,'SC500 MIPI / CSI-2 接收与 RAW10 解包\n每拍四像素，形成 40 位原始数据','process'),
    ('stream',2,'封装 AXI4-Stream\n生成 SOF、行末、数据有效标记','process'),
    ('busy',3,'帧首检查：前一帧 ISP 尾部仍忙？','decision'),
    ('isp',4,'接受整帧，执行 ISP\nBayer BGGR 去马赛克 → 帧级白平衡','process'),
    ('ddr',5,'跨时钟 FIFO 与 DDR 视频缓存\n按帧组织写入和显示读出，解耦采集 / 显示','process'),
    ('parallel',6,'并行生成各显示支路\n原图、均衡灰度、中值、Sobel\n卡通、运动区域、帧差','process'),
    ('mode',7,'C7 去抖后选择本地算法\n每路 RGB 与自身 VS / DE 配套输出','process'),
    ('source_select',8,'SW2/B4 选择本地或 A 板网络视频\n双级同步、20 ms 去抖、帧消隐时提交','process'),
    ('display',9,'叠加 OSD、Logo、检测框与云图等信息\n输出 1280 × 720 HDMI，像素时钟 75 MHz','process'),
    ('end',10,'结束（本帧处理）','end')]:f.step(sid,row,text,kind)
f.step('drop',4,'拒绝当前整帧\n保留旧 ISP / FIFO 状态\n等待下一帧',side='right')
f.chain('start','capture','stream','busy')
f.edge('busy','isp',label='否');f.edge('busy','drop',(1,.5),(.5,1),label='是')
f.chain('isp','ddr','parallel','mode','source_select','display','end')
f.edge('drop','end',(1,.5),(1,.5),
    corners=[(20.8,f.y(4)),(20.8,f.y(10))],dashed=True)
f.finish('对应：当前 B 板正式 design_top_wrapper.v；ISP_TAIL_FRAME_GUARD = 1，网络 / 本地路径独立运行。')

# White balance has concurrent pixel and frame-statistic paths. Do not imply
# that a whole frame is buffered while the serial divider computes its gains.
f=Flow(7,'白平衡算法',height=24.5)
f.box('start',11,21.4,4.5,.85,'开始',WHITE,'ellipse')
f.box('input',11,19.5,7,1.15,'输入去马赛克 RGB888\n每拍四像素，按 ready / valid 接收')
for sid,x,y,text in [
    ('read_gain',5.5,17.3,'实时像素路径\n读取本帧活动 R / B 增益，G 增益为 1'),
    ('multiply',5.5,15.2,'四像素并行乘法\nR × gainR；B × gainB；G 直通'),
    ('clip',5.5,13.1,'Q16 乘法截位\n溢出时饱和至 255'),
    ('pixel_out',5.5,11,'同步 valid / SOF / EOL\n实时输出校正后的 RGB888'),
    ('sample',16.5,17.3,'帧级统计路径：每四像素拍抽取一像素\n仅累加 R + G + B < 720 的样本'),
    ('latch',16.5,15.2,'帧边界锁存 sumR / sumG / sumB\n本帧累加器重新置 1，避免零分母'),
    ('gain_r',16.5,13.1,'共享串行除法器先求 R 增益\ngainR = (sumG << 16) / sumR'),
    ('gain_b',16.5,11,'再求 B 增益\ngainB = (sumG << 16) / sumB'),
    ('pending',16.5,8.9,'增益限幅至 20 位\n写入 pending 寄存器'),
    ('commit',16.5,6.8,'后续帧起始原子提交两通道增益\n活动增益在整个帧内保持不变')]:
    f.box(sid,x,y,6,1.15,text,size=16.5)
f.box('end',11,1.9,4.5,.85,'结束（本次处理）',WHITE,'ellipse')
f.edge('start','input')
f.edge('input','read_gain',(.2,0),(.5,1),corners=[(8.9,18.25),(5.5,18.25)])
f.edge('input','sample',(.8,0),(.5,1),corners=[(13.1,18.25),(16.5,18.25)])
f.chain('read_gain','multiply','clip','pixel_out')
f.chain('sample','latch','gain_r','gain_b','pending','commit')
f.edge('commit','read_gain',(0,.5),(1,.5),
    corners=[(11,6.8),(11,17.3)],dashed=True)
f.label('gain_note',12.2,10,1.8,.8,'新增益\n帧级提交',13)
f.edge('pixel_out','end',(.5,0),(0,.5),corners=[(5.5,1.9)])
f.edge('commit','end',(.5,0),(1,.5),corners=[(16.5,1.9)])
f.finish('对应：正式登记的 user_source/hdl_source/awb.v；以 G 通道为参考，像素通路不等待串行除法。')

f=Flow(8,'自动曝光算法',12)
for sid,row,text,kind in [
    ('start',0,'开始','start'),('init',1,'初始化曝光与增益\n曝光 1990；增益 112','process'),
    ('sample',2,'每 16 组 RAW10 采样一组\n四像素各取高 8 位，累加亮度和与样本数','process'),
    ('cdc',3,'帧边界锁存统计，经 Toggle CDC 到配置域\n统计稳定且样本组数 ≥ 256 后更新控制','process'),
    ('enabled',4,'自动曝光使能？','decision'),('dark',5,'亮度低于 102？','decision'),
    ('bright',6,'亮度高于 118？','decision'),('hold',7,'位于 102…118 滞回区\n曝光与增益保持不变','process'),
    ('pending',8,'形成待更新 / 恢复参数\n未发生变化时不产生配置请求','process'),
    ('ready',9,'有待写请求，且相机初始化\n与上次曝光配置均完成？','decision'),
    ('write',10,'脉冲 O_ae_req，提交曝光 / 增益\nuicfgcs500 经 I²C 写入传感器\n等待配置完成，后续帧继续统计','process'),
    ('end',11,'结束（本轮控制）','end')]:f.step(sid,row,text,kind)
f.step('off',5,'关闭时停止自动更新\n从开到关时请求恢复\n曝光 1990 / 增益 112',side='right')
f.step('increase',6,'偏暗：曝光先加 32，最大 1990\n曝光到顶后增益加 1，最大 143',side='left')
f.step('decrease',7,'偏亮：增益先减 1，最小 16\n增益到底后曝光减 32，最小 32',side='right')
f.step('wait',9,'保持当前参数\n继续等待接口就绪',side='left')
f.chain('start','init','sample','cdc','enabled')
f.edge('enabled','dark',label='是');f.edge('enabled','off',(1,.5),(.5,1),label='否')
f.edge('dark','bright',label='否');f.edge('dark','increase',(0,.5),(.5,1),label='是')
f.edge('bright','hold',label='否');f.edge('bright','decrease',(1,.5),(.5,1),label='是')
f.edge('hold','pending');f.edge('increase','pending',(.5,0),(0,.5))
f.edge('decrease','pending',(.5,0),(1,.5))
f.edge('off','pending',(1,.5),(1,.5),corners=[(20.8,f.y(5)),(20.8,f.y(8))])
f.edge('pending','ready');f.edge('ready','write',label='是')
f.edge('ready','wait',(0,.5),(1,.5),label='否')
f.edge('wait','ready',(.5,1),(.5,1),corners=[(3.7,f.y(9)+1.08),(11,f.y(9)+1.08)])
f.edge('write','end')
f.finish('对应：auto_exposure.v、uicfgcs500_720p.v；目标亮度 110±8，使用亮度总和比较以避免除法。')

def save():
    path=ROOT/'图像采集与处理_八算法流程图.json'
    spec={'title':'图像采集与处理：八算法流程图','pages':PAGES}
    path.write_text(json.dumps(spec,ensure_ascii=False,indent=2),encoding='utf-8')
    return path

if __name__=='__main__':
    print(save())
    print(f'{len(PAGES)} pages')
