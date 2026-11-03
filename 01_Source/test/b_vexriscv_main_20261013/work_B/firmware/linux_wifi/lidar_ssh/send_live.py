"""COM22 valid point frames to existing direct SSH: max 5 FPS, one pending + one in flight."""
from pathlib import Path
import argparse,datetime,hashlib,json,queue,shlex,struct,subprocess,sys,threading,time
from protocol import validate_file
from live_protocol import Framer,LatestFrame,verify_ack,wait_rate
from send_static import D,F,W,R,SOURCE,ssh_config,network_preflight

def ppp_delta(path):
    rows=[]
    for line in path.read_text(errors='replace').splitlines():
        if line.strip().startswith('ppp0:'):
            values=[int(v) for v in line.split(':',1)[1].split()]
            if len(values)==16:rows.append(values)
    if len(rows)!=2:raise ValueError('Missing PPP before/after counters')
    return {key:rows[1][index]-rows[0][index] for key,index in
      [('rx_errors',2),('rx_drop',3),('tx_errors',10),('tx_drop',11)]}

class Source:
    def __init__(self,slot,port,baud,replay):
        self.slot=slot;self.framer=Framer();self.stop=threading.Event();self.error=None;self.serial=None;self.replay=None
        if replay:
            data=replay.read_bytes();validate_file(data);decoder=Framer();self.replay=decoder.feed(data)
            if not self.replay:raise ValueError('Replay has no point frames')
        else:
            sys.path.insert(0,str(W/'tools/uart_loader/vendor'));import serial
            self.serial=serial.Serial();self.serial.port=port;self.serial.baudrate=baud
            self.serial.timeout=.1;self.serial.dtr=False;self.serial.rts=False
            self.serial.open() # Fail before lengthy SSH if L150 already owns the port.
        self.thread=threading.Thread(target=self.read,daemon=True);self.thread.start()

    def read(self):
        try:
            index=0
            while not self.stop.is_set():
                if self.replay:
                    raw,_=self.replay[index%len(self.replay)];index+=1
                    frames=self.framer.feed(raw)
                else:frames=self.framer.feed(self.serial.read(4096))
                for raw,fields in frames:self.slot.put((time.perf_counter(),raw,fields))
                if self.replay:self.stop.wait(.2)
        except Exception as error:self.error=str(error)

    def close(self):
        self.stop.set();self.thread.join(timeout=2)
        if self.serial:self.serial.close()

class Lines:
    def __init__(self,process,path):
        self.process=process;self.queue=queue.Queue(maxsize=32);self.error=None
        self.thread=threading.Thread(target=self.read,args=(path,),daemon=True);self.thread.start()

    def read(self,path):
        try:
            with path.open('wb',buffering=0) as log:
                while True:
                    line=self.process.stdout.readline(4097)
                    if not line:break
                    log.write(line)
                    if len(line)>4096:raise ValueError('Oversized remote output line')
                    self.queue.put(line,timeout=5)
        except Exception as error:self.error=str(error)
        finally:
            try:self.queue.put(None,timeout=1)
            except queue.Full:pass

    def next(self,timeout=30):
        if self.error:raise RuntimeError(self.error)
        try:line=self.queue.get(timeout=timeout)
        except queue.Empty:raise TimeoutError('Linux acknowledgement timeout')
        if line is None:raise RuntimeError('SSH closed; inspect saved SSH/stderr/remote logs')
        return line.rstrip(b'\r\n')

    def until(self,marker,timeout=30):
        while True:
            line=self.next(timeout)
            if line==marker:return
            if line.startswith(b'{'):raise RuntimeError('Unexpected receiver event during deployment: '+line.decode())

def remote_command(binary,helper,tag):
    q=shlex.quote;copier='/tmp/lidar_live_copy.'+tag;part='/tmp/lidar_stream.'+tag+'.part'
    sha=hashlib.sha256(binary).hexdigest();hsha=hashlib.sha256(helper).hexdigest()
    return ("uname -m; printf 'LIDAR_LIVE_PPP_BEFORE\\n'; cat /proc/net/dev; free; printf 'LIDAR_LIVE_PREFLIGHT_OK\\n'; "
      f"dd bs=1 count={len(helper)} of={q(copier)} 2>/dev/null || exit 21; "
      f"digest=$(sha256sum {q(copier)}) || exit 21; case \"$digest\" in {q(hsha+'  '+copier)}) ;; *) exit 21;; esac; "
      f"chmod 755 {q(copier)} || exit 21; printf 'LIDAR_BOOTSTRAP_OK\\n'; {q(copier)} 3>&1 >{q(part)} || exit 22; "
      f"digest=$(sha256sum {q(part)}) || exit 22; case \"$digest\" in {q(sha+'  '+part)}) ;; *) exit 22;; esac; "
      f"chmod 755 {q(part)} && /bin/busybox mv {q(part)} /tmp/lidar_stream || exit 23; "
      "/tmp/lidar_stream; rc=$?; printf 'LIDAR_LIVE_PPP_AFTER\\n'; cat /proc/net/dev; free; exit \"$rc\"")

def deploy(process,lines,binary,helper):
    lines.until(b'LIDAR_LIVE_PREFLIGHT_OK',600)
    print('SSH_REMOTE_COMMAND_PASS; deploying small RAM-only receiver...',flush=True)
    process.stdin.write(helper);process.stdin.flush();lines.until(b'LIDAR_BOOTSTRAP_OK')
    process.stdin.write(struct.pack('<I',len(binary)));process.stdin.flush();lines.until(b'LIDAR_COPY_READY')
    for offset in range(0,len(binary),512):
        process.stdin.write(binary[offset:offset+512]);process.stdin.flush();lines.until(b'LIDAR_BLOCK_OK')
    event=json.loads(lines.next())
    if event.get('event')!='stream_ready' or event.get('seq')!=0:raise ValueError('Linux stream receiver did not start')
    print('LINUX_STREAM_READY; source is drained during login, newest frames only; max 5 FPS.',flush=True)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',default='COM22');p.add_argument('--baud',type=int,default=230400)
    p.add_argument('--seconds',type=int,default=60,help='60-second acceptance by default; 0 runs until Ctrl+C')
    p.add_argument('--replay',type=Path,help='File replay over SSH; not live Bluetooth acceptance')
    a=p.parse_args()
    if a.seconds<0:raise ValueError('--seconds must be >= 0')
    acceptance=json.loads((D/'build/static_acceptance.json').read_text())
    if acceptance.get('status')!='PASS_STATIC_TRANSFER_AND_LINUX_VALIDATION':raise ValueError('Complete static acceptance first')
    binary=(D/'build/lidar_stream').read_bytes();helper=(D/'build/copy_exact').read_bytes()
    for data,name in [(binary,'stream_manifest.json'),(helper,'copy_manifest.json')]:
        if hashlib.sha256(data).hexdigest()!=json.loads((D/'build'/name).read_text())['sha256']:raise ValueError('Executable manifest mismatch')
    tag=datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f');base=R/('live_'+tag)
    state=dict(started=datetime.datetime.now().isoformat(),source='FILE_REPLAY' if a.replay else a.port,
      baud=a.baud,max_FPS=5,receiver_bytes=len(binary),status='STARTED',pending_capacity=1,inflight_capacity=1,
      FPGA_modified=False,ESP_modified=False,physical_live_test=not bool(a.replay))
    process=None;source=None;lines=None;sent=acked=payload=0;started=None;interrupted=False
    latencies=dict(min=float('inf'),max=0.,total=0.);ages=dict(min=float('inf'),max=0.,total=0.)
    print('Connect Anlu-B-Linux; keep B/ESP powered. COM15 console may stay open.',flush=True)
    print('If using COM22 directly, close L150/other COM22 readers. This sender does not draw a map.',flush=True)
    print('Report:',base,flush=True)
    try:
        state['network']=network_preflight();slot=LatestFrame();source=Source(slot,a.port,a.baud,a.replay)
        settings=ssh_config();settings[settings.index('-E')+1]=str(base)+'.ssh.log'
        command=remote_command(binary,helper,tag)
        with base.with_suffix('.stderr.log').open('wb') as err,base.with_suffix('.frames.jsonl').open('w',encoding='utf8') as frames:
            process=subprocess.Popen([*settings,command],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err)
            lines=Lines(process,base.with_suffix('.remote.log'))
            setup_timer=threading.Timer(900,process.kill);setup_timer.daemon=True;setup_timer.start()
            try:deploy(process,lines,binary,helper)
            finally:setup_timer.cancel()
            started=time.perf_counter();last_sent=started-.2;last_status=started-1;first_sent=None
            baseline=dict(source.framer.stats);replaced_start=slot.replaced
            state['startup_source']=baseline;state['startup_replaced']=replaced_start
            try:
                while not a.seconds or time.perf_counter()-started<a.seconds:
                    if source.error:raise RuntimeError('Source reader: '+source.error)
                    wait_rate(last_sent)
                    item=slot.take(.2)
                    if item is None:continue
                    arrived,raw,fields=item
                    send_time=time.perf_counter()
                    if a.seconds and send_time-started>=a.seconds:break
                    last_sent=send_time
                    if first_sent is None:first_sent=last_sent
                    process.stdin.write(raw);process.stdin.flush();sent+=1;payload+=len(raw)
                    event=json.loads(lines.next());verify_ack(event,raw,fields,sent);acked+=1
                    now=time.perf_counter();rtt=(now-last_sent)*1000;age=(last_sent-arrived)*1000
                    for values,value in [(latencies,rtt),(ages,age)]:
                        values['min']=min(values['min'],value);values['max']=max(values['max'],value);values['total']+=value
                    frames.write(json.dumps(dict(sent_seconds=last_sent-started,ack_seconds=now-started,round_trip_ms=rtt,
                      source_age_at_send_ms=age,linux=event))+'\n');frames.flush()
                    if now-last_status>=1:
                        tx_fps=(sent-1)/(last_sent-first_sent) if sent>1 else 0.
                        print('LIVE ack=%d source_valid=%d replaced=%d points=%d robot=(%d,%d) yaw=%d RTT=%.1fms TX_FPS=%.2f'%
                          (acked,source.framer.stats['point_frames'],slot.replaced-replaced_start,
                           fields['points'],fields['rx'],fields['ry'],fields['yaw_mrad'],rtt,tx_fps),flush=True)
                        last_status=now
            except KeyboardInterrupt:interrupted=True
            active_ended=time.perf_counter();source.close();process.stdin.close()
            done=json.loads(lines.next())
            if done.get('event')!='stream_done' or done.get('seq')!=acked:raise ValueError('Missing/mismatched Linux stream completion')
            while True:
                try:lines.next(30)
                except RuntimeError:
                    if lines.error:raise
                    break
            code=process.wait(timeout=10)
            if code or not acked:raise RuntimeError('SSH exit=%s; acknowledged=%s'%(code,acked))
            seconds=active_ended-started
            delta=ppp_delta(base.with_suffix('.remote.log'))
            state.update(status='USER_STOPPED' if interrupted else 'PASS_REPLAY_ONLY' if a.replay else 'PASS_PHYSICAL_LIVE_SESSION',
              sent=sent,acknowledged=acked,payload_bytes=payload,elapsed_seconds=seconds,achieved_FPS=acked/seconds,
              send_interval_FPS=(sent-1)/(last_sent-first_sent) if sent>1 else 0.,
              payload_Bps=payload/seconds,replaced_during_live=slot.replaced-replaced_start,source_stats=source.framer.stats,
              ack_round_trip_ms=dict(min=latencies['min'],mean=latencies['total']/acked,max=latencies['max']),
              source_age_at_send_ms=dict(min=ages['min'],mean=ages['total']/acked,max=ages['max']),linux_final=done,
              PPP_counter_delta=delta,cleanup_seconds=time.perf_counter()-active_ended,
              rate_scope='Steady live phase only; RTT includes SSH/network/Linux processing, not one-way radar latency',
              limits='Highest 5 FPS; achieved rate is measured, may be lower. No HDMI/map/STM32/FPGA/ESP changes.')
            if any(delta.values()):
                state['status']='DATA_VALID_BUT_PPP_COUNTERS_CHANGED'
                print('LIVE_LINK_UNSTABLE: frames validated but PPP counters changed:',delta,flush=True);return 1
            print('LIVE_LIDAR_STOPPED' if interrupted else 'REPLAY_LIDAR_PASS' if a.replay else 'LIVE_LIDAR_PASS',
                  'ack=',acked,'FPS=%.2f'%(acked/seconds),'payload=%.1f B/s'%(payload/seconds),flush=True)
            return 0
    except (Exception,KeyboardInterrupt) as error:
        state.update(status='FAIL_OR_INTERRUPTED',error=str(error),sent=sent,acknowledged=acked)
        print('LIVE_LIDAR_FAIL:',error,'; logs retained:',base,flush=True);return 1
    finally:
        if source:
            source.close();state['source_stats']=dict(source.framer.stats);state['source_reader_error']=source.error
        if process:
            try:process.stdin.close()
            except (OSError,ValueError):pass
            if process.poll() is None:
                try:process.wait(timeout=2)
                except subprocess.TimeoutExpired:process.kill();process.wait()
        if lines:lines.thread.join(timeout=2)
        state['finished']=datetime.datetime.now().isoformat();base.with_suffix('.json').write_text(json.dumps(state,indent=2))

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,RuntimeError) as error:print('ERROR:',error,file=sys.stderr);raise SystemExit(1)
