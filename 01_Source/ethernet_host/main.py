"""FPGA Ethernet video workstation. All board communication is receive-only."""
from __future__ import annotations
import argparse
from collections import deque
from dataclasses import asdict
from pathlib import Path
import ipaddress
import json
import queue
import socket
import struct
import sys
import threading
import time

from PyQt5 import QtCore, QtGui, QtWidgets
from protocol import Assembler, Frame, Metadata, VIDEO_WIDTH, VIDEO_HEIGHT

APP_DIR = Path(sys.executable).parent if getattr(sys, 'frozen', False) else Path(__file__).parent
RESOURCE_DIR = Path(getattr(sys, '_MEIPASS', Path(__file__).parent))


def image_of(frame):
    return QtGui.QImage(frame.rgb, frame.width, frame.height, frame.width * 3, QtGui.QImage.Format_RGB888).copy()


class Receiver(threading.Thread):
    def __init__(self, bind_ip, port, expected_ip, expected_port):
        super().__init__(daemon=True)
        self.decoder = Assembler(expected_ip, expected_port)
        self.frames = queue.Queue(maxsize=4)
        self.errors = queue.Queue()
        self.stop_event = threading.Event()
        self.last_packet = 0.0
        self.started = time.monotonic()
        self.frame_times = deque(maxlen=180)
        self.preview_skips = 0
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
            self.sock.bind((bind_ip, port))
            self.sock.settimeout(0.2)
        except Exception:
            self.sock.close()
            raise

    def run(self):
        try:
            while not self.stop_event.is_set():
                try:
                    data, peer = self.sock.recvfrom(65535)
                except socket.timeout:
                    self.decoder.expire()
                    continue
                self.last_packet = time.monotonic()
                frame = self.decoder.feed(data, peer)
                if frame:
                    self.frame_times.append(frame.received_monotonic)
                    try:
                        self.frames.put_nowait(frame)
                    except queue.Full:
                        try:
                            self.frames.get_nowait()
                        except queue.Empty:
                            pass
                        self.preview_skips += 1
                        self.frames.put_nowait(frame)
        except OSError as exc:
            if not self.stop_event.is_set():
                self.errors.put(str(exc))
        except Exception as exc:
            self.errors.put(f'{type(exc).__name__}: {exc}')
        finally:
            self.sock.close()

    def stop(self):
        self.stop_event.set()
        self.join(timeout=1)

    def fps(self):
        values = list(self.frame_times)
        if len(values) < 2 or time.monotonic() - values[-1] > 2:
            return 0.0
        return (len(values) - 1) / max(values[-1] - values[0], 0.001)


class VideoView(QtWidgets.QWidget):
    def __init__(self):
        super().__init__()
        self.setMinimumSize(640, 480)
        self.frame = None
        self.picture = QtGui.QImage()
        self.show_bbox = True
        self.show_history = True

    def set_frame(self, frame):
        self.frame, self.picture = frame, image_of(frame)
        self.update()

    def paintEvent(self, event):
        p = QtGui.QPainter(self)
        p.fillRect(self.rect(), QtGui.QColor('#101820'))
        if self.picture.isNull():
            p.setPen(QtGui.QColor('#a8b7c7'))
            p.drawText(self.rect(), QtCore.Qt.AlignCenter,
                       '等待 FPGA 视频\n640 × 360 · RGB565 / 兼容旧版\n请先连接网线，再开始监听')
            return
        size = self.picture.size().scaled(self.size(), QtCore.Qt.KeepAspectRatio)
        target = QtCore.QRect((self.width()-size.width())//2, (self.height()-size.height())//2,
                              size.width(), size.height())
        p.setRenderHint(QtGui.QPainter.SmoothPixmapTransform, False)
        p.drawImage(target, self.picture)
        m = self.frame.metadata
        if self.show_bbox and self.frame.display_bbox is not None and (m.same_source or self.show_history):
            color = QtGui.QColor('#40ed9c' if m.same_source else '#ffbf47')
            pen = QtGui.QPen(color, 2)
            if not m.same_source:
                pen.setStyle(QtCore.Qt.DashLine)
            p.setPen(pen)
            x1,y1,x2,y2 = self.frame.display_bbox
            sx,sy = target.width()/self.frame.width, target.height()/self.frame.height
            box = QtCore.QRectF(target.x()+x1*sx, target.y()+y1*sy,
                                (x2-x1+1)*sx, (y2-y1+1)*sy)
            p.drawRect(box)
            title = '人体 · 同源帧' if m.same_source else '历史结果 · 非当前源帧'
            label = QtCore.QRectF(box.x(), max(target.y(),box.y()-23), min(230,target.width()),23)
            p.fillRect(label, QtGui.QColor('#182832'))
            p.drawText(label.adjusted(5,0,-2,0), QtCore.Qt.AlignVCenter, title)


class Window(QtWidgets.QMainWindow):
    def __init__(self, demo=False):
        super().__init__()
        self.setWindowTitle('FPGA 以太网视频上位机 · 人体识别 · 640×360')
        self.resize(1180, 820)
        self.receiver = None
        self.shown_frame = None
        self.capture_remaining = 0
        self.demo = demo
        self.demo_stop = threading.Event()
        self.analysis_frame = None
        self.analysis_path = None
        self.build_ui()
        self.process = QtCore.QProcess(self)
        self.process.finished.connect(self.analysis_finished)
        self.process.errorOccurred.connect(self.analysis_error)
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self.poll)
        self.timer.start(30)
        self.log('就绪。当前 FPGA 默认发往电脑 192.168.137.1:6001；本程序不修改网卡或 FPGA。')
        if demo:
            self.filter_source.setChecked(False)
            self.bind_ip.setText('127.0.0.1')
            self.port.setValue(16001)
            self.statusBar().showMessage('本地演示：模拟 UDP 数据，非实板检测结果')
            self.setWindowTitle(self.windowTitle()+'【本地演示】')
            QtCore.QTimer.singleShot(150, self.start)

    def build_ui(self):
        central = QtWidgets.QWidget()
        self.setCentralWidget(central)
        root = QtWidgets.QVBoxLayout(central)
        root.setContentsMargins(18,14,18,12)
        title = QtWidgets.QLabel('FPGA 视频与检测结果')
        title.setStyleSheet('font-size:23px;font-weight:600;color:#163350')
        root.addWidget(title)
        sub = QtWidgets.QLabel('UDP v3 · 640×360 RGB565 / 兼容 v2 旧版   ·   源帧与检测结果关联')
        sub.setStyleSheet('color:#65758a;padding-bottom:6px')
        root.addWidget(sub)
        network = QtWidgets.QHBoxLayout()
        self.bind_ip = QtWidgets.QLineEdit('0.0.0.0');self.bind_ip.setMaximumWidth(140)
        self.port = QtWidgets.QSpinBox();self.port.setRange(1,65535);self.port.setValue(6001)
        self.source_ip = QtWidgets.QLineEdit('192.168.137.2');self.source_ip.setMaximumWidth(145)
        self.source_port = QtWidgets.QSpinBox();self.source_port.setRange(1,65535);self.source_port.setValue(6002)
        self.filter_source = QtWidgets.QCheckBox('限定 FPGA 来源');self.filter_source.setChecked(True)
        self.start_button = QtWidgets.QPushButton('开始监听');self.start_button.clicked.connect(self.start)
        self.stop_button = QtWidgets.QPushButton('停止');self.stop_button.clicked.connect(self.stop);self.stop_button.setEnabled(False)
        for w in [QtWidgets.QLabel('监听 IP'),self.bind_ip,QtWidgets.QLabel('端口'),self.port,
                  self.filter_source,self.source_ip,self.source_port,self.start_button,self.stop_button]:network.addWidget(w)
        network.addStretch();root.addLayout(network)
        self.state = QtWidgets.QLabel('未监听');self.state.setStyleSheet('padding:8px;background:#e8eef5;color:#28425f;border-radius:4px')
        root.addWidget(self.state)
        body = QtWidgets.QHBoxLayout()
        left = QtWidgets.QVBoxLayout();self.video = VideoView();left.addWidget(self.video,1)
        self.caption = QtWidgets.QLabel('新版视频 640×360，无模型补黑；旧版 160×120 自动识别。保存图像不含上位机叠框。')
        self.caption.setWordWrap(True)
        self.caption.setStyleSheet('color:#65758a');left.addWidget(self.caption)
        controls = QtWidgets.QHBoxLayout()
        self.freeze = QtWidgets.QCheckBox('冻结显示')
        self.boxes = QtWidgets.QCheckBox('显示检测框');self.boxes.setChecked(True)
        self.history = QtWidgets.QCheckBox('显示历史框（橙色虚线）')
        self.history.setChecked(True)
        self.history.setToolTip('NPU结果通常晚于当前视频帧。默认叠加最近一次有效FPGA结果；橙色虚线表示不同源帧。')
        self.boxes.toggled.connect(self.display_options);self.history.toggled.connect(self.display_options)
        for w in [self.freeze,self.boxes,self.history]:controls.addWidget(w)
        controls.addStretch();left.addLayout(controls)
        body.addLayout(left,1)
        side = QtWidgets.QVBoxLayout()
        self.details = {}
        group = QtWidgets.QGroupBox('接收与推理状态');form = QtWidgets.QFormLayout(group)
        for key,name in [('fps','视频帧率'),('count','完整视频帧'),('bad','异常包 / 不完整帧'),('missing','视频帧序号缺口'),
                         ('fid','UDP 视频帧号'),('sid','图像源帧号'),('rid','推理结果编号'),('bsid','结果源帧号'),
                         ('detect','检测状态'),('bbox','模型框坐标（160×120）'),('sync','同步标签'),('score','FPGA OBJ / PERSON')]:
            label = QtWidgets.QLabel('—');label.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
            label.setWordWrap(True);self.details[key]=label;form.addRow(name,label)
        self.details['score'].setText('当前协议未发送分数')
        side.addWidget(group)
        capture = QtWidgets.QGroupBox('保存原始数据');cl=QtWidgets.QVBoxLayout(capture)
        self.save_button=QtWidgets.QPushButton('保存当前原始帧');self.save_button.clicked.connect(self.save_current)
        cl.addWidget(self.save_button)
        row=QtWidgets.QHBoxLayout();self.capture_count=QtWidgets.QSpinBox();self.capture_count.setRange(1,300);self.capture_count.setValue(12)
        self.capture_button=QtWidgets.QPushButton('保存随后 N 张完整帧');self.capture_button.clicked.connect(self.capture_next)
        row.addWidget(self.capture_count);row.addWidget(self.capture_button);cl.addLayout(row)
        self.folder=QtWidgets.QLineEdit(str(APP_DIR/'captures'))
        browse=QtWidgets.QPushButton('选择保存目录');browse.clicked.connect(self.choose_folder)
        cl.addWidget(self.folder);cl.addWidget(browse);side.addWidget(capture)
        analysis=QtWidgets.QGroupBox('Python 人体模型对照（可选）');al=QtWidgets.QVBoxLayout(analysis)
        self.python_path=QtWidgets.QLineEdit(str(Path.home()/'.conda/envs/yolo/python.exe'))
        self.model_path=QtWidgets.QLineEdit(str(Path.home()/'Desktop/safety_grid_v1'))
        self.python_path.setPlaceholderText('已安装 PyTorch 的 python.exe')
        self.model_path.setPlaceholderText('人体模型工程目录')
        al.addWidget(QtWidgets.QLabel('Python 路径 / 模型工程目录'));al.addWidget(self.python_path);al.addWidget(self.model_path)
        self.analyze_button=QtWidgets.QPushButton('用人体 QAT 模型分析当前帧');self.analyze_button.clicked.connect(self.analyze)
        self.analyze_button.setToolTip('新版 RGB565 视频将抽样回160×90并上下补黑；色彩已有量化，只能作近似模型对照。')
        self.analysis_label=QtWidgets.QLabel('对照分数来自电脑模型，不能当作 FPGA 实测分数。');self.analysis_label.setWordWrap(True)
        al.addWidget(self.analyze_button);al.addWidget(self.analysis_label);side.addWidget(analysis);side.addStretch()
        panel=QtWidgets.QWidget();panel.setLayout(side);panel.setMinimumWidth(340);panel.setMaximumWidth(390)
        scroll=QtWidgets.QScrollArea();scroll.setWidget(panel);scroll.setWidgetResizable(True);scroll.setMinimumWidth(360)
        body.addWidget(scroll);root.addLayout(body,1)
        self.logs=QtWidgets.QPlainTextEdit();self.logs.setReadOnly(True);self.logs.setMaximumHeight(95);self.logs.setMaximumBlockCount(300)
        root.addWidget(self.logs)

    def log(self,text):
        self.logs.appendPlainText(time.strftime('%H:%M:%S')+'  '+text)

    def display_options(self):
        self.video.show_bbox=self.boxes.isChecked();self.video.show_history=self.history.isChecked();self.video.update()

    def choose_folder(self):
        value=QtWidgets.QFileDialog.getExistingDirectory(self,'选择保存目录',self.folder.text())
        if value:self.folder.setText(value)

    def start(self):
        if self.receiver:return
        try:
            ip=str(ipaddress.IPv4Address(self.bind_ip.text().strip()))
            source=str(ipaddress.IPv4Address(self.source_ip.text().strip())) if self.filter_source.isChecked() else ''
            self.receiver=Receiver(ip,self.port.value(),source,self.source_port.value() if source else 0)
        except Exception as exc:
            self.receiver=None
            QtWidgets.QMessageBox.warning(self,'无法开始监听',f'{exc}\n\n请检查 IP 是否属于本机，以及端口是否被其他接收软件占用。')
            return
        self.shown_frame=None;self.video.frame=None;self.video.picture=QtGui.QImage();self.video.update()
        self.receiver.start();self.start_button.setEnabled(False);self.stop_button.setEnabled(True)
        for w in [self.bind_ip,self.port,self.source_ip,self.source_port,self.filter_source]:w.setEnabled(False)
        self.log(f'监听 {ip}:{self.port.value()}；来源 '+(f'{source}:{self.source_port.value()}' if source else '不限'))
        if self.demo:
            self.demo_stop.clear()
            threading.Thread(target=send_demo,args=('127.0.0.1',self.port.value(),self.demo_stop),daemon=True).start()

    def stop(self):
        self.demo_stop.set()
        if self.receiver:self.receiver.stop();self.receiver=None
        self.capture_remaining=0;self.capture_button.setText('保存随后 N 张完整帧')
        self.start_button.setEnabled(True);self.stop_button.setEnabled(False)
        for w in [self.bind_ip,self.port,self.source_ip,self.source_port,self.filter_source]:w.setEnabled(True)
        self.state.setText('已停止监听；保留最后一张图像');self.log('监听已停止')

    def poll(self):
        r=self.receiver
        if not r:return
        if not r.errors.empty():
            error=r.errors.get();self.stop();self.state.setText('接收异常：'+error);return
        latest=None
        while True:
            try:frame=r.frames.get_nowait()
            except queue.Empty:break
            latest=frame
            if self.capture_remaining:
                try:self.save_frame(frame)
                except Exception as exc:
                    self.log('保存失败：'+str(exc));self.capture_remaining=0;break
                self.capture_remaining-=1
                self.capture_button.setText(f'保存中，剩余 {self.capture_remaining} 张' if self.capture_remaining else '保存随后 N 张完整帧')
        if latest and not self.freeze.isChecked():
            self.shown_frame=latest;self.video.set_frame(latest);self.update_metadata(latest)
        st=r.decoder.stats
        self.details['fps'].setText(f'{r.fps():.1f} FPS')
        self.details['count'].setText(str(st.complete_frames))
        self.details['bad'].setText(f'{st.invalid_packets} / {st.incomplete_frames}')
        self.details['missing'].setText(str(st.missing_frames))
        elapsed=max(time.monotonic()-r.started,.001)
        if st.complete_frames and r.fps()>0:
            state=f'正在接收 · {st.bytes_received*8/elapsed/1e6:.2f} Mbit/s · 有效包 {st.valid_packets} · 重复包 {st.duplicate_packets}'
            if self.freeze.isChecked():state+=' · 显示已冻结，接收继续'
        elif not st.datagrams:
            state='监听中，尚未收到数据。请确认网线、电脑 192.168.137.1、防火墙及 FPGA 发送状态。'
        elif not st.valid_packets:
            state=f'收到 {st.datagrams} 包，尚无有效图像包；过滤 {st.filtered_packets}，协议异常 {st.invalid_packets}。'
        else:state='有数据，但暂时没有新的完整视频帧。新版须收齐360包，旧版须收齐42包。'
        if self.demo:state='【本地模拟数据】'+state
        self.state.setText(state)

    def update_metadata(self,frame):
        m=frame.metadata
        self.details['fid'].setText(f'{frame.frame_id} · UDP v{m.version or 1} · {frame.width}×{frame.height}')
        self.caption.setText(f'接收尺寸 {frame.width}×{frame.height}；'+
                             ('RGB565 色彩重建，检测框已去模型补边并映射到画面。' if m.version==3 else '上下各15行黑边属于模型输入补边。')+
                             '保存图像不含上位机叠框。')
        for key,value in [('sid',m.source_frame_id),('rid',m.bbox_result_id),('bsid',m.bbox_source_frame_id)]:
            self.details[key].setText(str(value) if m.version in (2,3) else '旧协议未提供')
        if m.version not in (2,3):status='旧协议不含检测结果'
        elif not m.bbox_source_valid:status='暂无已发布推理结果'
        elif not m.bbox_valid:status='已发布结果：无有效人体框'
        elif m.same_source:status='检测到人体 · 与图像同源'
        else:status='有效历史框 · 与当前图像不同源'
        self.details['detect'].setText(status)
        self.details['bbox'].setText(str(m.bbox) if m.bbox_valid else '—')
        self.details['sync'].setText(f'{m.sync_id}（有效）' if m.sync_valid else '无同步标签')

    def save_frame(self,frame):
        folder=Path(self.folder.text()).expanduser();folder.mkdir(parents=True,exist_ok=True)
        base=folder/f'frame_{time.time_ns()}_udp{frame.frame_id:05d}_src{frame.metadata.source_frame_id:05d}'
        raw=base.with_suffix('.rgb');png=base.with_suffix('.png');meta=base.with_suffix('.json')
        raw.write_bytes(frame.rgb)
        if not image_of(frame).save(str(png),'PNG'):raise OSError('PNG保存失败')
        info=frame.describe();info['raw_file']=raw.name;info['png_file']=png.name
        meta.write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
        return raw

    def save_current(self):
        if not self.shown_frame:self.log('还没有可保存的完整视频帧');return
        try:self.log('已保存原始 RGB、PNG 和 metadata：'+str(self.save_frame(self.shown_frame)))
        except Exception as exc:self.log('保存失败：'+str(exc))

    def capture_next(self):
        if self.capture_remaining:
            self.capture_remaining=0;self.capture_button.setText('保存随后 N 张完整帧');return
        if not self.receiver:self.log('请先开始监听');return
        self.capture_remaining=self.capture_count.value();self.capture_button.setText(f'保存中，剩余 {self.capture_remaining} 张')

    def analyze(self):
        if not self.shown_frame:self.log('请先接收完整视频帧');return
        if self.process.state()!=QtCore.QProcess.NotRunning:return
        python=Path(self.python_path.text());model=Path(self.model_path.text())
        if not python.is_file() or not (model/'runs/qat_person_v3/best_qat.pth').is_file():
            QtWidgets.QMessageBox.warning(self,'模型对照路径不正确','请选择装有 PyTorch 的 Python，以及含 runs/qat_person_v3/best_qat.pth 的人体模型工程。');return
        try:self.analysis_path=self.save_frame(self.shown_frame)
        except Exception as exc:self.log('保存待分析帧失败：'+str(exc));return
        self.analysis_frame=self.shown_frame
        self.analyze_button.setEnabled(False);self.analysis_label.setText('正在分析保存的原始帧，视频接收继续…')
        self.process.setProgram(str(python))
        self.process.setArguments([str(RESOURCE_DIR/'analyze_person.py'),str(self.analysis_path),'--model-dir',str(model)])
        self.process.start()

    def analysis_error(self,error):
        if error==QtCore.QProcess.FailedToStart:
            self.analyze_button.setEnabled(True);self.analysis_label.setText('Python 启动失败，请检查解释器路径。')

    def analysis_finished(self,exit_code,status):
        self.analyze_button.setEnabled(True)
        output=bytes(self.process.readAllStandardOutput()).decode('utf-8',errors='replace')
        error=bytes(self.process.readAllStandardError()).decode('utf-8',errors='replace')
        try:
            if exit_code:raise ValueError(error[-1600:] or output[-1600:])
            result=json.loads(next(line[7:] for line in output.splitlines() if line.startswith('RESULT ')))
            self.analysis_path.with_suffix('.analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
            s=result['winner'];f=self.analysis_frame
            kind='Python 近似对照（RGB565重建）' if f.metadata.version==3 else 'Python 对照'
            self.analysis_label.setText(f'{kind} · 源帧 {f.metadata.source_frame_id}\nOBJ={s["obj"]}  PERSON={s["person"]}\n'+
                                       ('满足128门限' if result['detected'] else '未满足128门限')+'\n这是电脑模型分数，非 FPGA 实测。')
            self.log(f'Python 对照完成：OBJ={s["obj"]}, PERSON={s["person"]}；结果已保存')
        except Exception as exc:
            self.analysis_label.setText('模型对照失败，详情见日志');self.log(str(exc))

    def closeEvent(self,event):
        if self.process.state()!=QtCore.QProcess.NotRunning:self.process.kill();self.process.waitForFinished(1000)
        if self.receiver:self.stop()
        event.accept()


def send_demo(ip,port,stop_event):
    """An explicitly labelled local demo, never claimed to be a board result."""
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);fid=0
    try:
        while not stop_event.is_set():
            rgb=bytearray()
            for y in range(VIDEO_HEIGHT):
                for x in range(VIDEO_WIDTH):
                    r,g,b=(x+fid*2)%256,(y*2)%256,(x+y+fid)%256
                    rgb.extend(struct.pack('>H', ((r>>3)<<11)|((g>>2)<<5)|(b>>3)))
            same=fid%90<45;source=fid&65535;bsource=source if same else (source-2)&65535
            meta=struct.pack('>HBBBBBBHHHH',123,1,40,25,110,100,2,source,bsource,fid//3+1,0)
            for pid in range(VIDEO_HEIGHT):
                chunk=rgb[pid*1280:(pid+1)*1280];flags=1 if pid==0 else 2 if pid==359 else 0
                sock.sendto(struct.pack('>HHHBB',fid&65535,pid,len(chunk),flags,3)+meta+chunk,(ip,port))
            fid=(fid+1)&65535
            stop_event.wait(1/25)
    finally:sock.close()


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--demo',action='store_true')
    parser.add_argument('--smoke-output',type=Path);parser.add_argument('--smoke-ms',type=int,default=1800)
    parser.add_argument('--smoke-person-rgb',type=Path)
    args=parser.parse_args()
    app=QtWidgets.QApplication(sys.argv[:1]);app.setFont(QtGui.QFont('Microsoft YaHei UI',9))
    app.setStyle('Fusion')
    window=Window(demo=args.demo);window.show()
    if args.smoke_output:
        if args.smoke_person_rgb:
            def check_person():
                window.freeze.setChecked(True)
                raw=args.smoke_person_rgb.read_bytes()
                window.shown_frame=Frame(0,Metadata(2),raw,('127.0.0.1',6002),time.time(),time.monotonic())
                window.video.set_frame(window.shown_frame)
                window.folder.setText(str(args.smoke_output/'saved_frames'))
                window.analyze()
            QtCore.QTimer.singleShot(700,check_person)
        deadline=time.monotonic()+45
        def finish():
            if window.process.state()!=QtCore.QProcess.NotRunning and time.monotonic()<deadline:
                QtCore.QTimer.singleShot(100,finish);return
            args.smoke_output.mkdir(parents=True,exist_ok=True)
            window.grab().save(str(args.smoke_output/'window.png'))
            stats=asdict(window.receiver.decoder.stats) if window.receiver else {}
            result=dict(statistics=stats,has_frame=window.shown_frame is not None,
                        detect_text=window.details['detect'].text(),demo=window.demo,
                        analysis_text=window.analysis_label.text())
            if window.shown_frame:
                window.folder.setText(str(args.smoke_output/'saved_frames'))
                raw=window.save_frame(window.shown_frame);result['saved_raw']=str(raw)
                result['raw_bytes']=raw.stat().st_size
            (args.smoke_output/'smoke.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
            window.close();app.quit()
        QtCore.QTimer.singleShot(args.smoke_ms,finish)
    return app.exec_()


if __name__=='__main__':sys.exit(main())
