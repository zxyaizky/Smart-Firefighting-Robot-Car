"""Native Visio engineering block diagram in the user's green/black reference style."""
from pathlib import Path
import hashlib
import json
import zipfile
import win32com.client

OUT = Path(__file__).resolve().parent
W, H = 30, 22
GREEN = 'RGB(146,208,80)'
app = win32com.client.GetActiveObject('Visio.Application')
doc = app.Documents.Add('')
page = doc.Pages.Item(1)
page.Name = '整体框架图_参考风格'
for key, value in [('PageWidth', W), ('PageHeight', H), ('DrawingScale', 1), ('PageScale', 1)]:
    page.PageSheet.CellsU(key).FormulaU = f'{value} in'
blocks, edges, borders = {}, [], []


def setc(shape, name, value):
    shape.CellsU(name).FormulaU = str(value)


def rect(key, x, y, w, h, text, green=False, size=17, bold=False, border=True):
    assert 0 <= x-w/2 < x+w/2 <= W and 0 <= y-h/2 < y+h/2 <= H
    s = page.DrawRectangle(x-w/2, y-h/2, x+w/2, y+h/2)
    s.NameU, s.Text = key, text
    for name, value in {'FillForegnd': GREEN if green else 'RGB(255,255,255)',
                        'FillPattern': 1, 'LineColor': 'RGB(0,0,0)',
                        'LineWeight': '1 pt', 'LinePattern': 1 if border else 0,
                        'Char.Font': 'FONT("Times New Roman")',
                        'Char.AsianFont': 'FONT("SimSun")',
                        'Char.Size': f'{size} pt', 'Char.Style': 1 if bold else 0,
                        'Char.Color': 'RGB(0,0,0)', 'Para.HorzAlign': 1,
                        'VerticalAlign': 1, 'LeftMargin': '.05 in',
                        'RightMargin': '.05 in', 'TopMargin': '.03 in',
                        'BottomMargin': '.03 in'}.items():
        setc(s, name, value)
    blocks[key] = {'shape': s, 'text': text, 'bounds': (x-w/2,y-h/2,x+w/2,y+h/2)}
    return s


def text(key, x, y, w, h, content, size=13, angle=0, bold=False):
    s = rect(key,x,y,w,h,content,size=size,bold=bold,border=False)
    setc(s,'FillPattern',0)
    if angle:
        setc(s,'Angle',f'{angle} deg')
    return s


def line(key, pts, both=False, arrow=True, dashed=False):
    assert len(pts)>=2 and all(0<=x<=W and 0<=y<=H for x,y in pts)
    s = page.DrawPolyline([v for p in pts for v in p],0)
    s.NameU = key
    for name,value in {'LineColor':'RGB(0,0,0)','LineWeight':'1.3 pt',
                       'FillPattern':0,'EndArrow':13 if arrow else 0,
                       'BeginArrow':13 if both else 0,'EndArrowSize':2,
                       'BeginArrowSize':2,'LinePattern':2 if dashed else 1}.items():
        setc(s,name,value)
    s.SendToBack()
    edges.append({'name':key,'points':pts})
    return s


text('title',15,21.55,28,.6,'双 FPGA 履带式消防医疗救援车整体框架图',29,bold=True)
for key,x,y,w,h in [('A_boundary',8.55,12.15,8.9,12.7),('B_boundary',20.55,12.15,10.9,12.7)]:
    borders.append(rect(key,x,y,w,h,''))
rect('A_board_title',8.0,18.5,3.2,.42,'FPGA A  /  PH1P35',size=19,bold=True,border=False)
rect('B_board_title',18.65,18.5,3.2,.42,'FPGA B  /  PH1P35',size=19,bold=True,border=False)

# External devices are white, internal logic is green, as in the supplied reference.
rect('A_camera',8.4,20.3,7.2,.8,'SC500 CMOS Camera A  (MIPI CSI-2)',size=21)
rect('B_camera',19.2,20.3,7.2,.8,'SC500 CMOS Camera B  (MIPI CSI-2)',size=21)
rect('A_DDR',1.7,14.2,2.5,2.5,'DDR\n图像 / NPU 参数',size=19)
rect('A_flash',1.7,9.4,2.5,1.3,'U33 Flash\nNPU 模型参数',size=18)
rect('A_clock_in',1.7,17.1,2.5,1.0,'50 MHz\n系统复位',size=18)
rect('B_DDR',28.2,14.8,2.5,2.2,'DDR\n视频 / Linux',size=20)
rect('B_clock_in',28.2,17.1,2.5,1.0,'50 MHz\n系统复位',size=18)
rect('HC_SR04',28.2,11,2.5,1.3,'HC-SR04\n超声波测距',size=19)
rect('MAX30102',28.2,8.6,2.5,1.3,'MAX30102\n心率 / 血氧',size=19)

# A: local video readback supplies independent NPU and Ethernet sampling paths.
rect('A_cfg',5.75,17.1,2.3,1.0,'Clock / Reset\n相机 I²C 配置',True,17)
rect('A_capture',10.05,17.1,4.4,1.0,'MIPI CSI-2 / RAW10 解包\nISP 图像处理',True,18)
rect('A_mem',5.75,14.2,2.3,2.8,'DDR Control\n视频写入 / 读取\n参数访问仲裁',True,17)
rect('A_video',10.05,14.5,4.4,1.2,'Video Read / Input Sampling\n1280 × 720 RGB → 推理 / 网络支路',True,17)
rect('A_npu',10.05,11.7,4.4,1.4,'NPU (person_detect)\n160 × 120 输入 / 人员推理\nBBox + Source / Result ID',True,18)
rect('A_boot',5.75,9.4,2.3,1.7,'MCU / Flash Bridge\nNPU 参数装载\nDDR 权重供给',True,16)
rect('A_ethernet',10.05,8.2,4.4,1.6,'Ethernet / UDP v3 TX\n640 × 360 RGB565 + BBox\nRGMII / PHY',True,19)
rect('A_local',5.75,6.85,2.3,.85,'HDMI / OSD\nVoice UART',True,16)
line('A_i2c',[(5.75,17.6),(5.75,19.9)],both=True)
text('A_i2c_label',5.45,18.9,2.05,.24,'O_cam_scl / IO_cam_sda',12,90)
line('A_mipi',[(10.05,19.9),(10.05,17.6)])
text('A_mipi_label',10.4,18.8,1.8,.35,'MIPI clk / data ±',14,90)
line('A_clock',[(2.95,17.1),(4.6,17.1)])
text('A_clock_label',3.75,17.55,1.7,.4,'I_sys_clk\nI_rst_n',12)
line('A_cfg_done',[(6.9,17.1),(7.85,17.1)])
text('A_cfg_done_label',7.37,17.4,.95,.3,'cfg_done',12)
line('A_capture_write',[(8.2,16.6),(8.2,15.9),(5.75,15.9),(5.75,15.6)])
text('A_isp_label',6.5,16.12,2.8,.3,'ISP RGB / frame_start',12)
line('A_ddr_bus',[(2.95,14.2),(4.6,14.2)],both=True)
text('A_ddr_label',3.75,14.85,1.65,.7,'ddr_dq / dqs\naddr / ba\nras / cas / we',12)
line('A_video_read',[(6.9,14.5),(7.85,14.5)])
text('A_video_read_label',7.37,14.85,1.05,.3,'RGB888',12)
line('A_npu_input',[(10.05,13.9),(10.05,12.4)])
text('A_npu_input_label',10.45,13.13,1.38,.35,'frame / byte',13,90)
line('A_flash_load',[(2.95,9.4),(4.6,9.4)])
text('A_flash_label',3.75,9.85,1.65,.35,'Flash / AHB',13)
line('A_param_ddr',[(5.75,10.25),(5.75,12.8)])
text('A_param_ddr_label',5.4,11.52,1.9,.3,'param / weight',13,90)
line('A_weight',[(6.9,13.1),(7.3,13.1),(7.3,11.7),(7.85,11.7)])
text('A_weight_label',7.45,12.35,1.25,.3,'weight',12,90)
line('A_clean_sample',[(12.25,14.5),(12.65,14.5),(12.65,8.65),(12.25,8.65)])
text('A_clean_sample_label',12.42,11.4,3.2,.3,'clean RGB / frame metadata',13,90)
line('A_bbox_to_eth',[(10.05,11.0),(10.05,9.0)])
text('A_bbox_label',10.43,10.0,1.8,.35,'BBox / result_id',13,90)
line('A_local_video',[(4.6,13.5),(4.35,13.5),(4.35,6.85),(4.6,6.85)])
line('A_local_voice',[(7.85,11.3),(7.1,11.3),(7.1,6.85),(6.9,6.85)])

# B: local HSV is independent of B4 display selection.
rect('B_cfg',16.8,17.1,2.3,1.0,'CMOS Init\nI²C 配置',True,17)
rect('B_capture',20.65,17.1,3.8,1.0,'MIPI / RAW10 / ISP\nVideo In / Out',True,18)
rect('B_clock',24.25,17.1,2.3,1.0,'Clock And Reset\nPLL / CDC',True,17)
rect('B_mem',24.25,14.8,2.3,1.9,'DDR Control\n本地 / 网络视频\nCPU 访问仲裁',True,16)
rect('B_source',20.65,14.4,3.8,1.15,'Video Source Select (B4)\nB 本地 / A 网络（2×）',True,18)
rect('B_color',16.8,14.0,2.3,1.5,'HSV Color Detect\nYellow → 火焰\nGreen → 物资\n去噪 / 框确认',True,16)
rect('B_sensors',16.8,10.95,2.3,1.15,'Sensor Mailbox\n人员 / 黄绿 / 距离\nCDC / 新鲜度',True,16)
rect('B_control',20.65,10.95,3.8,1.65,'Rescue Control\n绿色任务 → 人员近距停车\n→ 黄色消防 → 常规前进\nArm / Fire / Car / Voice',True,18)
rect('B_range',24.25,11,2.3,1.0,'HC-SR04 Ranging\n距离 / 有效标志',True,16)
rect('B_vitals',24.25,8.6,2.3,1.0,'MAX30102 / I²C\n心率 / SpO₂',True,17)
rect('B_rx',16.8,8.6,2.3,1.1,'Ethernet / UDP RX\n视频 DDR 双缓存\nBBox / Frame ID',True,16)
rect('B_linux',16.8,6.7,2.3,.95,'VexRiscv / Linux\nDDR 执行 / 点云 MMIO',True,16)
rect('B_display',20.65,7.1,3.8,1.1,'Video Effects / OSD / HDMI\n目标框 / 距离 / 血氧 / 云图',True,17)
line('B_i2c',[(16.8,17.6),(16.8,19.9)],both=True)
text('B_i2c_label',16.46,18.8,1.8,.3,'O_cam_scl / IO_cam_sda',12,90)
line('B_mipi',[(20.65,19.9),(20.65,17.6)])
text('B_mipi_label',21.0,18.8,1.8,.3,'MIPI clk / data ±',14,90)
line('B_init',[(17.95,17.1),(18.75,17.1)])
text('B_init_label',18.35,17.4,.8,.3,'cfg_done',12)
line('B_clock_in',[(26.95,17.1),(25.4,17.1)])
text('B_clock_label',26.17,17.6,1.55,.5,'I_sys_clk\nI_rst_n',12)
line('B_domain_clock',[(23.1,17.1),(22.55,17.1)])
text('B_domain_label',22.83,17.55,.8,.5,'clk\nrst_n',12)
line('B_ISP_DDR',[(21.8,16.6),(21.8,16.05),(24.25,16.05),(24.25,15.75)])
text('B_ISP_DDR_label',23.05,16.28,2.6,.3,'128-bit video write',12)
line('B_ddr_bus',[(25.4,14.8),(26.95,14.8)],both=True)
text('B_ddr_label',26.18,15.45,1.5,.65,'ddr_dq / dqs\naddr / ctrl',12)
line('B_read_source',[(23.1,14.4),(22.55,14.4)])
text('B_source_rgb',22.84,14.8,.65,.4,'RGB',12)
line('B_read_hsv',[(23.1,15.35),(16.8,15.35),(16.8,14.75)])
text('B_read_hsv_label',19.25,15.58,3.3,.3,'本地原始 RGB / 像素坐标',13)
line('B_HSV_results',[(16.8,13.25),(16.8,11.525)])
text('B_HSV_label',16.4,12.35,1.65,.3,'yellow / green',13,90)
line('B_sensors_control',[(17.95,10.95),(18.75,10.95)])
text('B_sensors_control_label',18.35,11.42,1.3,.5,'flags\nrange_mm',12)
line('B_range_trig',[(25.4,11.3),(26.95,11.3)])
text('B_trig_label',26.18,11.57,1.55,.3,'hcsr04_trig_out',12)
line('B_range_echo',[(26.95,10.7),(25.4,10.7)])
text('B_echo_label',26.18,10.43,1.55,.3,'hcsr04_echo_in',12)
line('B_range_mailbox',[(23.1,11),(22.8,11),(22.8,12.4),(16.8,12.4),(16.8,11.525)])
text('B_range_bus_label',20.0,12.65,3.0,.3,'distance_mm / valid',13)
line('B_vitals_i2c',[(25.4,8.6),(26.95,8.6)],both=True)
text('B_vitals_i2c_label',26.18,9.07,1.55,.5,'max30102\nscl / sda',12)
line('B_vitals_osd',[(24.25,8.1),(24.25,7.1),(22.55,7.1)])
text('B_vitals_osd_label',24.72,7.56,1.4,.3,'HR / SpO₂',13)
line('AB_ethernet',[(12.25,8.2),(14.0,8.2),(14.0,8.6),(15.65,8.6)])
text('AB_ethernet_label',13.9,9.3,2.6,.7,'RGMII / PHY\nEthernet UDP\nRGB565 + BBox',14)
line('B_person',[(16.8,9.15),(16.8,10.375)])
text('B_person_label',17.18,9.78,1.1,.3,'person',13,90)
line('B_network_video',[(17.95,8.6),(18.4,8.6),(18.4,14.4),(18.75,14.4)])
text('B_network_video_label',18.12,13.15,1.3,.3,'network RGB',12,90)
line('B_selected_to_osd',[(20.65,13.825),(20.65,13.4),(23.0,13.4),(23.0,7.5),(22.55,7.5)])
line('B_map_to_osd',[(17.95,6.7),(18.35,6.7),(18.35,7.1),(18.75,7.1)])
text('B_map_to_osd_label',18.4,7.7,1.7,.55,'MMIO / Map\n201 × 201',12)
line('B_color_linux',[(15.65,14.0),(15.35,14.0),(15.35,6.7),(15.65,6.7)],dashed=True)
text('B_color_linux_label',15.98,7.65,1.45,.3,'detect meta',12)
line('B_person_linux',[(16.8,8.05),(16.8,7.175)],dashed=True)

# B Linux Flash boot: CPU ROM copies the payload through the existing DDR master.
rect('B_flash',28.2,12.75,2.5,.95,'U33 Flash（合成镜像）\nFPGA + Linux + MCU',size=15)
rect('B_flash_loader',24.25,12.75,2.3,.95,'MCU / AHB Bridge\nCPU ROM Loader',True,15)
line('B_flash_read',[(26.95,12.75),(25.4,12.75)],both=True)
text('B_flash_read_label',26.18,13.3,1.55,.28,'Flash Read / AHB',11)
line('B_linux_copy_ddr',[(24.25,13.225),(24.25,13.85)])
text('B_linux_copy_label',25.2,13.53,1.8,.28,'CPU copy / CRC32',11)
line('B_rom_flash_access',[(17.95,6.7),(18.1,6.7),(18.1,12.75),(23.1,12.75)],both=True)
text('B_rom_flash_access_label',20.2,13.02,3.3,.28,'ROM Loader: Flash → DDR',11)
text('B_boot_chain',7.0,2.4,12.5,.6,'B 板启动：合成镜像写入 U33 Flash\nMCU / AHB 桥 → CPU ROM Loader → DDR → SBI / Linux',14)
# End B Linux Flash boot.

# Visible peripherals and the main control interfaces.
rect('A_local_out',5.75,3.65,3.5,1.0,'A 板本地 HDMI\n语音模块',size=20)
rect('car_out',11.2,3.65,3.8,1.1,'STM32 → 履带底盘\n前进 / 后退 / 转向 / 停车',size=19)
rect('arm_out',16.4,3.65,3.5,1.1,'六关节机械臂\n抓取 / 搬运 / 回位',size=20)
rect('fire_out',21.0,3.65,3.5,1.1,'瞄准舵机 / 水泵驱动\n黄色火焰消防',size=20)
rect('voice_out',25.7,3.65,2.8,1.1,'语音播报模块\n火焰 / 物资 / 人员',size=17)
line('A_local_out_bus',[(5.75,6.425),(5.75,4.15)])
text('A_local_out_label',6.1,5.22,1.9,.3,'TMDS / UART TX',13,90)
line('B_car_out',[(18.75,10.65),(18.3,10.65),(18.3,5.2),(11.2,5.2),(11.2,4.2)])
text('B_car_out_label',12.45,5.45,3.9,.3,'O_car_uart_tx  (9600 8N1)',14)
line('B_arm_out',[(19.4,10.125),(19.4,8.0),(18.6,8.0),(18.6,4.85),(16.4,4.85),(16.4,4.2)])
text('B_arm_out_label',16.4,4.55,2.9,.3,'O_arm_pwm[5:0]',14)
line('B_fire_out',[(22.55,10.3),(22.75,10.3),(22.75,4.85),(21,4.85),(21,4.2)])
text('B_fire_out_label',21.0,4.55,3.8,.3,'servo_pwm_out / pump_ctrl_out',12)
line('B_voice_out',[(22.55,11.55),(26.4,11.55),(26.4,4.55),(25.7,4.55),(25.7,4.2)])
text('B_voice_out_label',25.85,5.18,2.4,.45,'O_voice_uart_tx\n9600 8N1',13)
rect('B_HDMI_out',22.0,1.3,4.5,.95,'HDMI 综合显示 (1280 × 720)',size=21)
line('B_HDMI_out_bus',[(22.55,6.85),(29.65,6.85),(29.65,1.3),(24.25,1.3)])
text('B_HDMI_out_label',28.78,5.3,2.15,.7,'O_tmds_ch[0:2]_p\nO_tmds_clk_p',14)
rect('radar_in',2.8,1.3,4.5,.95,'L150 / STM32 / JDY-33\n雷达蓝牙串口',size=18)
rect('pc_forward',8.1,1.3,4.0,.95,'PC  /  Windows\n串口采集与 send_map.py',size=18)
rect('esp_link',12.3,1.3,3.0,.95,'ESP32\nWi-Fi / UART PPP',size=18)
line('radar_pc',[(5.05,1.3),(6.1,1.3)])
text('radar_pc_label',5.58,1.64,1.1,.3,'Serial',12)
line('pc_esp',[(10.1,1.3),(10.8,1.3)])
text('pc_esp_label',10.45,1.68,1.1,.3,'Wi-Fi',12)
line('esp_linux',[(13.8,1.3),(14.4,1.3),(14.4,6.7),(15.65,6.7)])
text('esp_linux_label',14.75,4.25,2.0,.3,'UART / PPP / SSH',13,90)
text('footnote',15,.35,29,.4,'框内绿色为 FPGA 功能模块，框外白色为外设；连线标注主接口 / 信号组。依据当前源码结构绘制，非实板验收图。',14)

# Borders remain behind all native editable lines and blocks.
for s in borders:
    s.SendToBack()
manifest = json.loads((OUT/'来源核对.json').read_text(encoding='utf-8'))
for record in manifest['sources'].values():
    p = Path(record['path'])
    assert hashlib.sha256(p.read_bytes()).hexdigest() == record['sha256'], f'Source changed: {p}'
base = OUT/'双FPGA救援车_整体框架图_参考风格'
doc.SaveAs(str(base.with_suffix('.vsdx')))
app.Settings.SetRasterExportResolution(0,120,120,0)
for suffix in ('.png','.svg'):
    page.Export(str(base.with_suffix(suffix)))
with zipfile.ZipFile(base.with_suffix('.vsdx')) as package:
    xml = package.read('visio/pages/page1.xml').decode('utf-8')
    assert all(s in xml for s in ['Rescue Control','NPU (person_detect)','MAX30102','Ethernet'])
manifest.update(style='user reference: white / black / green engineering blocks',
                shapes=page.Shapes.Count, edges=len(edges), native_vsdx_check='PASS')
(OUT/'参考风格_核对.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
app.ActiveWindow.ViewFit=1
print(json.dumps({'path':str(base.with_suffix('.vsdx')),'shapes':page.Shapes.Count,'check':'PASS'},ensure_ascii=False))
