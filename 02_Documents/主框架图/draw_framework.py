"""Create an editable Visio overview from the current A/B project sources."""
from pathlib import Path
import hashlib
import json
import re
import zipfile
import pythoncom
import win32com.client

OUT = Path(__file__).resolve().parent
ROOT = OUT.parent
A = ROOT / 'lab_ex3_osd_SC500_720/lab_ex3_osd'
B = ROOT / 'test/b_vexriscv_main_20261013/work_B'
AT = A / 'user_source/hdl_source/design_top_wrapper.v'
BT = B / 'firmware/linux_wifi/lidar_hdmi/rtl/design_top_wrapper.v'
W, H = 24, 15
COLORS = {'video': (39, 101, 166), 'detect': (183, 112, 20),
          'control': (39, 124, 97), 'map': (121, 83, 162),
          'ink': (37, 51, 67), 'muted': (98, 111, 126)}

app = win32com.client.GetActiveObject('Visio.Application')
app.Visible = True
doc = app.Documents.Add('')
page = doc.Pages.Item(1)
page.Name = '系统主框架图'
page.PageSheet.CellsU('PageWidth').FormulaU = f'{W} in'
page.PageSheet.CellsU('PageHeight').FormulaU = f'{H} in'
page.PageSheet.CellsU('DrawingScale').FormulaU = '1 in'
page.PageSheet.CellsU('PageScale').FormulaU = '1 in'
nodes = {}
edges = []


def rgb(value):
    if isinstance(value, str):
        value = COLORS[value]
    return 'RGB(%d,%d,%d)' % value


def cell(shape, name, formula):
    shape.CellsU(name).FormulaU = str(formula)


def box(key, x, y, w, h, text, fill=(255, 255, 255), stroke=(201, 211, 222),
        size=14, color='ink', bold=False):
    assert 0 <= x-w/2 < x+w/2 <= W and 0 <= y-h/2 < y+h/2 <= H
    shape = page.DrawRectangle(x-w/2, y-h/2, x+w/2, y+h/2)
    shape.NameU = key
    shape.Text = text
    for name, val in {'FillForegnd': rgb(fill), 'FillPattern': 1,
                      'LineColor': rgb(stroke), 'LineWeight': '0.8 pt',
                      'Char.Size': f'{size} pt', 'Char.Color': rgb(color),
                      'Char.Style': 1 if bold else 0,
                      'Para.HorzAlign': 1, 'VerticalAlign': 1,
                      'LeftMargin': '0.07 in', 'RightMargin': '0.07 in',
                      'TopMargin': '0.03 in', 'BottomMargin': '0.03 in'}.items():
        cell(shape, name, val)
    # Font lookup uses the installed Visio font collection.
    cell(shape, 'Char.Font', 'FONT("Microsoft YaHei")')
    cell(shape, 'Char.AsianFont', 'FONT("Microsoft YaHei")')
    if key:
        nodes[key] = {'shape': shape, 'rect': (x-w/2, y-h/2, x+w/2, y+h/2), 'text': text}
    return shape


def label(key, x, y, w, h, text, size=12, color='muted', bold=False):
    sh = box(key, x, y, w, h, text, size=size, color=color, bold=bold)
    cell(sh, 'FillPattern', 0)
    cell(sh, 'LinePattern', 0)
    return sh


def path(key, points, kind='video', arrow=True, dashed=False):
    assert len(points) >= 2
    assert all(0 <= x <= W and 0 <= y <= H for x, y in points)
    coords = [v for pt in points for v in pt]
    sh = page.DrawPolyline(coords, 0)
    sh.NameU = key
    cell(sh, 'LineColor', rgb(kind))
    cell(sh, 'LineWeight', '1.5 pt')
    cell(sh, 'FillPattern', 0)
    cell(sh, 'EndArrow', 13 if arrow else 0)
    cell(sh, 'EndArrowSize', 2)
    if dashed:
        cell(sh, 'LinePattern', 2)
    # Lines sit behind blocks; endpoints are intentionally on block boundaries.
    sh.SendToBack()
    edges.append({'id': key, 'points': points, 'kind': kind})
    return sh


# Background panels are sent behind connectors once all shapes are present.
panels = []
for key, x, width, title in [('panel_a', 3.4, 5.8, 'A 板  |  视觉推理与视频发送'),
                              ('panel_b', 12.5, 11.0, 'B 板  |  识别、救援控制与综合显示'),
                              ('panel_out', 21.05, 4.9, '显示与执行终端')]:
    panels.append(box(key, x, 8.65, width, 9.25, '', fill=(246, 248, 251), stroke=(217, 225, 234)))
    label(key+'_title', x, 12.91, width-.3, .38, title, 17, 'ink', True)
panels.append(box('panel_map', 12, 2.38, 23, 2.7, '', fill=(248, 246, 251), stroke=(225, 217, 236)))
label('map_title', 5.1, 3.37, 8.6, .38, '雷达数据链路  |  经电脑转发到 B 板 Linux', 16, 'map', True)
label('title', 12, 14.34, 23, .58, '双 FPGA 消防医疗救援车 · 系统主框架图', 29, 'ink', True)
label('subtitle', 12, 13.74, 23, .35, '依据当前工程源码绘制  ·  A：camera_to_dsi_display  /  B：camera_to_dsi_display_lidar  ·  2026-10-31', 12)

# A board: the NPU and clean Ethernet image both branch from DDR readback.
box('a_camera', 3.4, 12.05, 4.85, .67, 'SC500 摄像头 A  ·  MIPI CSI-2', fill=(234, 242, 251))
box('a_isp', 3.4, 10.92, 4.85, .88, 'CSI / RAW10 解包 → ISP\nDDR 图像缓存与读取  ·  1280 × 720', fill=(234, 242, 251))
box('a_local', 1.94, 9.43, 2.1, .91, 'A 板本地显示\nHDMI / 调试叠加', size=13)
box('a_npu', 4.77, 9.43, 2.2, .91, 'NPU 人员检测\n输入 160 × 120', fill=(255, 246, 229), size=13)
box('a_params', 4.77, 7.88, 2.2, .84, 'U33 Flash 参数\n经 MCU / DDR 供给', size=12)
box('a_voice', 1.94, 7.88, 2.1, .84, '本地语音 UART\nNPU 结果提示', size=12)
box('a_tx', 3.4, 5.4, 4.85, 1.12, 'RGB565 视频采样 + 人员框 / 帧号\nUDP v3 封装 → RGMII / PHY\n640 × 360  ·  最高 30 fps', fill=(234, 242, 251), size=14)
label('a_note', 3.4, 6.66, 4.8, .45, '视频与推理输入为独立支路', 11)
path('a_capture', [(3.4,11.715),(3.4,11.36)])
path('a_local_video', [(2.15,10.48),(2.15,10.12),(1.94,10.12),(1.94,9.885)])
path('a_npu_input', [(4.77,10.48),(4.77,9.885)])
path('a_model_params', [(4.77,8.3),(4.77,8.975)], 'detect', dashed=True)
path('a_voice_result', [(3.67,9.43),(3.12,9.43),(3.12,7.88),(2.99,7.88)], 'detect')
path('a_clean_video', [(.975,10.92),(.73,10.92),(.73,5.4),(.975,5.4)])
path('a_bbox', [(5.87,9.43),(6.09,9.43),(6.09,5.8),(5.825,5.8)], 'detect')

# B board: local color analysis stays independent of the HDMI source selection.
box('b_camera', 8.65, 12.05, 2.8, .67, 'SC500 摄像头 B', fill=(234, 242, 251))
box('b_medical', 12.5, 12.05, 2.8, .67, 'MAX30102  ·  I²C', fill=(234, 246, 240))
box('b_range', 16.3, 12.05, 2.8, .67, 'HC-SR04  ·  Trig / Echo', fill=(234, 246, 240), size=13)
box('b_isp', 8.65, 10.92, 2.8, .88, 'CSI / ISP + DDR\n本地原始图像读取', fill=(234, 242, 251))
box('b_color', 8.65, 9.43, 2.8, .98, '全画面 HSV 黄绿识别\n黄色：火焰  /  绿色：物资\n去噪、确认与目标框', fill=(255, 246, 229), size=12)
box('b_mailbox', 12.5, 9.43, 2.8, .98, '感知结果跨时钟汇合\n人员 + 黄绿目标 + 距离\n新鲜度 / 故障处理', fill=(255, 246, 229), size=12)
box('b_control', 16.3, 9.43, 2.8, 1.22, '救援状态机与优先级\n绿色任务 → 近距人员停车\n→ 黄色消防 → 常规前进\nE11 自动使能 / 取消', fill=(234, 246, 240), size=12)
box('b_source', 8.65, 7.36, 2.8, 1.02, 'B4 视频源选择\n高：B 本地图像\n低：A 网络图像（2×）', fill=(234, 242, 251), size=13)
box('b_osd', 12.5, 7.36, 2.8, 1.02, '图像模式 / OSD 叠加\n目标框、距离、心率 / 血氧\nC7 切换 7 种图像模式', fill=(234, 242, 251), size=12)
box('b_map', 16.3, 7.36, 2.8, 1.02, '雷达云图叠加 → HDMI\n201 × 201 地图\n图像 + 状态 + 云图', fill=(241, 234, 249), size=13)
box('b_rx', 8.65, 5.4, 2.8, 1.12, 'RGMII / UDP 接收\n网络视频 DDR 双缓存\n人员框 / 帧号解析', fill=(234, 242, 251), size=13)
box('b_cpu', 12.5, 5.4, 2.8, 1.12, 'VexRiscv + Linux\nDDR 运行 / U33 启动\nSSH 点云接收与地图生成', fill=(241, 234, 249), size=12)
box('b_mmio', 16.3, 5.4, 2.8, 1.12, '地图 MMIO / 双缓冲\n0xF0020000\n目标元数据供近似着色', fill=(241, 234, 249), size=12)
path('a_to_b', [(5.825,5.4),(7.25,5.4)])
label('eth_label',6.55,6.05,1.12,.46,'以太网\n视频 + 框',10,'video')
path('b_capture', [(8.65,11.715),(8.65,11.36)])
path('b_hsv_input', [(8.65,10.48),(8.65,9.92)])
path('b_local_source', [(7.25,10.92),(7.08,10.92),(7.08,7.36),(7.25,7.36)])
path('b_color_results', [(10.05,9.43),(11.1,9.43)], 'detect')
path('b_range_result', [(16.3,11.715),(16.3,10.6),(12.5,10.6),(12.5,9.92)], 'detect')
path('b_person_results', [(10.05,5.75),(10.56,5.75),(10.56,9.04),(11.1,9.04)], 'detect')
path('b_sensor_control', [(13.9,9.43),(14.9,9.43)], 'detect')
path('b_network_source', [(8.65,5.96),(8.65,6.85)])
path('b_selected_video', [(10.05,7.36),(11.1,7.36)])
path('b_composite_video', [(13.9,7.36),(14.9,7.36)])
path('b_vitals', [(12.5,11.715),(12.5,11.18),(14.23,11.18),(14.23,8.17),(12.5,8.17),(12.5,7.87)], 'detect')
label('vitals_label',13.35,11.53,2.3,.28,'心率 / 血氧',10,'detect')
path('cpu_map_write', [(13.9,5.4),(14.9,5.4)], 'map')
path('mmio_display', [(16.3,5.96),(16.3,6.85)], 'map')
# This abstract metadata bus represents the two independent detector connections.
path('detect_metadata', [(10.05,9.68),(10.8,9.68),(10.8,6.5),(17.9,6.5),(17.9,5.4),(17.7,5.4)], 'detect', dashed=True)
path('person_map_metadata', [(10.05,5.0),(10.35,5.0),(10.35,4.3),(16.3,4.3),(16.3,4.84)], 'detect', dashed=True)
label('metadata_label',12.75,6.27,3.5,.25,'黄绿 / 人员元数据',10,'detect')

# Execution leaves show their hardware interface and avoid internal pin clutter.
box('out_car', 21.05, 12.05, 4.05, .91, 'UART 9600 → STM32 → 履带底盘\n前进 / 后退 / 转向 / 停车', fill=(234, 246, 240), size=14)
box('out_arm', 21.05, 10.5, 4.05, .91, '6 路 PWM → 六关节机械臂\n接近 → 抓取 → 搬运 → 回位 / 离开', fill=(234, 246, 240), size=13)
box('out_fire', 21.05, 9.0, 4.05, .91, 'PWM 瞄准舵机 + GPIO 水泵驱动\n黄色火焰近距瞄准 / 定时喷水', fill=(234, 246, 240), size=14)
box('out_hdmi', 21.05, 7.36, 4.05, 1.02, 'HDMI 综合显示\n本地 / A 板视频、识别框、距离\n心率 / 血氧、雷达点云', fill=(234, 242, 251), size=14)
box('out_voice', 21.05, 5.4, 4.05, .91, 'UART 9600 → 语音模块\n火焰 / 物资 / 人员提示', fill=(234, 246, 240), size=14)
path('control_trunk', [(17.7,9.63),(18.3,9.63),(18.3,12.05),(19.025,12.05)], 'control')
path('arm_cmd', [(18.3,10.5),(19.025,10.5)], 'control')
path('fire_cmd', [(17.7,9.23),(18.3,9.23),(18.3,9.0),(19.025,9.0)], 'control')
path('voice_cmd', [(17.7,8.99),(18.12,8.99),(18.12,4.52),(21.05,4.52),(21.05,4.945)], 'control')
path('hdmi_output', [(17.7,7.36),(19.025,7.36)])
label('actuation_note',21.05,4.15,4.6,.28,'机械臂 / 瞄准舵机采用 PWM 命令',10)

# External radar path: no direct L150-to-FPGA wire is implied.
box('radar', 2.8, 2.35, 3.7, .9, 'L150 雷达 / STM32\nJDY-33 蓝牙串口输出', size=14)
box('pc', 8.1, 2.35, 4.0, .9, 'Windows 电脑\n串口采集 → send_map.py', size=14)
box('esp', 13.5, 2.35, 4.0, .9, 'Wi-Fi → ESP32\nUART / PPP 链路', size=14)
box('linux_entry', 19.65, 2.35, 5.0, .9, 'B 板 Linux 接收点云\n栅格化 / 近似目标关联 → 写地图 MMIO', size=14)
path('radar_pc',[(4.65,2.35),(6.1,2.35)],'map')
path('pc_esp',[(10.1,2.35),(11.5,2.35)],'map')
path('esp_linux',[(15.5,2.35),(17.15,2.35)],'map')
path('linux_cpu',[(19.65,2.8),(19.65,3.65),(12.5,3.65),(12.5,4.84)],'map')
label('map_limit',12,1.47,21.8,.35,'雷达链路承担地图显示与近似着色；救援状态机的距离输入来自 HC-SR04。摄像头与雷达关联采用近似前视匹配。',12,'map')

# Legend and verification boundary.
for i,(kind, title) in enumerate([('video','视频数据'),('detect','识别 / 传感结果'),('control','执行控制'),('map','点云 / 地图')]):
    xx = 2.0 + 5.5*i
    path('legend_'+kind,[(xx,.72),(xx+.62,.72)],kind)
    label('legend_text_'+kind,xx+1.8,.72,2.2,.3,title,11,kind)
label('boundary',12,.24,23,.32,'依据源码连接关系整理；图中功能不代表当前 bitstream 已部署或实板验收。未启用的双目测距、旧红色检测未列入。',11)
for panel in panels:
    panel.SendToBack()

# Verify owning project references and core instance evidence before saving.
sources = {'A_project': A/'td_project/camera_to_dsi_display.al',
           'B_project': B/'td_project/camera_to_dsi_display_lidar.al',
           'A_top': AT, 'B_top': BT,
           'B_control': B/'firmware/linux_wifi/lidar_hdmi/rtl/rescue/rescue_control.v',
           'map_sender': B/'firmware/linux_wifi/lidar_hdmi/send_map.py',
           'map_overlay': B/'firmware/linux_wifi/lidar_hdmi/rtl/lidar_map_overlay.v'}
assert '../firmware/linux_wifi/lidar_hdmi/rtl/design_top_wrapper.v' in sources['B_project'].read_text(encoding='utf-8-sig')
bt = BT.read_text(encoding='utf-8-sig')
assert all(token in bt for token in ['u_rescue_control','u_rescue_color','u_arm_auto','u_rescue_voice','u_max30102_top','u_lidar_map','hcsr04_2020_ranging_inst'])
base = OUT / '双FPGA救援车_系统主框架图'
doc.SaveAs(str(base.with_suffix('.vsdx')))
page.Export(str(base.with_suffix('.svg')))
# Set a useful raster export size through the native Visio settings.
try:
    app.Settings.SetRasterExportResolution(0, 150, 150, 0)
except pythoncom.com_error:
    pass
page.Export(str(base.with_suffix('.png')))
app.ActiveWindow.ViewFit = 1
manifest = {'page': page.Name, 'size_inches':[W,H], 'nodes':len(nodes), 'edges':len(edges),
            'sources': {k:{'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for k,p in sources.items()}}
with zipfile.ZipFile(base.with_suffix('.vsdx')) as z:
    xml = z.read('visio/pages/page1.xml').decode('utf-8')
    assert '救援状态机' in xml and 'MAX30102' in xml
    assert len(re.findall(r'<Shape\b', xml)) >= len(nodes)
manifest['vsdx_package_check'] = 'PASS'
(OUT/'来源核对.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'output':str(base.with_suffix('.vsdx')),'shapes':page.Shapes.Count,'check':'PASS'},ensure_ascii=False))
