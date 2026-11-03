"""One existing OpenSSH connection, binary stdin, three saved-file round trips by default."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,shlex,struct,subprocess,sys,threading,time
from protocol import validate_file

D=Path(__file__).resolve().parent;F=D.parent;W=F.parents[1]
R=W/'reports/lidar_ssh_20261025'
SOURCE=Path('C:/Users/lx292/Desktop/safety_grid_v1/lidar_10frames.bin')
REMOTE_FILE='/tmp/lidar_10frames.bin'


def ssh_config():
    command=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(F/'ssh_windows.ps1'),'-Direct','-ExportConfig']
    result=subprocess.run(command,capture_output=True,text=True,errors='replace',timeout=20)
    if result.returncode:raise RuntimeError('Existing SSH configuration: '+result.stderr)
    config=json.loads(result.stdout.lstrip('\ufeff'))
    return [config['Executable'],'-T','-vv','-E',str(R/'unused.ssh.log'),*config['Arguments']]


def network_preflight():
    wifi=subprocess.run(['netsh','wlan','show','interfaces'],capture_output=True,text=True,errors='replace',timeout=15)
    ssids=re.findall(r'^\s*SSID\s*:\s*(.*?)\s*$',wifi.stdout,re.M)
    if 'Anlu-B-Linux' not in ssids:raise RuntimeError('Connect Windows Wi-Fi to Anlu-B-Linux, then run again; SSH was not started')
    route=subprocess.run(['powershell.exe','-NoProfile','-Command',
      "@(Find-NetRoute -RemoteIPAddress '192.168.11.2') | Select-Object InterfaceAlias,IPAddress,DestinationPrefix,NextHop | ConvertTo-Json -Compress"],
      capture_output=True,text=True,errors='replace',timeout=20)
    if route.returncode:raise RuntimeError('Cannot read the existing direct route: '+route.stderr)
    rows=json.loads(route.stdout);rows=rows if isinstance(rows,list) else [rows]
    if not any(row.get('NextHop')=='192.168.4.1' for row in rows):
        raise RuntimeError('No existing route to Linux through ESP 192.168.4.1; save this result and check the proven direct SSH route')
    return dict(ssid='Anlu-B-Linux',route=rows)


def parse_output(output,original,copies,expected):
    offset=0;events=[];text=[];readbacks={}
    while offset<len(output):
        end=output.find(b'\n',offset)
        if end<0:raise ValueError('truncated remote output line')
        line=output[offset:end].rstrip(b'\r');offset=end+1
        if not line.startswith(b'{'):
            text.append(line.decode('utf8',errors='replace'));continue
        item=json.loads(line);events.append(item)
        if item.get('event')=='readback':
            size=item['bytes'];round_number=item['round']
            if size!=len(original) or round_number in readbacks:raise ValueError('readback size/round')
            received=output[offset:offset+size];offset+=size
            if received!=original:raise ValueError(f'round {round_number}: Linux saved-file bytes differ from Windows')
            if output[offset:offset+1]!=b'\n':raise ValueError('readback delimiter')
            offset+=1
            readbacks[round_number]=hashlib.sha256(received).hexdigest()
    if set(readbacks)!=set(range(1,copies+1)):raise ValueError('not all file round trips completed')
    for round_number in range(1,copies+1):
        summaries=[e for e in events if e.get('event')=='summary' and e['round']==round_number]
        if len(summaries)!=1:raise ValueError('missing Linux file summary')
        summary=summaries[0]
        for key,value in [('bytes',len(original)),('frames',len(expected['frames'])),('point_frames',expected['point_frames']),('points',expected['points']),('errors',0)]:
            if summary.get(key)!=value:raise ValueError('Linux summary mismatch: '+key)
        actual=[e for e in events if e.get('event')=='frame' and e['round']==round_number]
        wanted=[e for e in expected['frames'] if e['type']==2]
        if len(actual)!=len(wanted):raise ValueError('Linux parsed-frame count mismatch')
        for a,b in zip(actual,wanted):
            if any(a.get(k)!=v for k,v in b.items()):raise ValueError('Linux robot/point metadata differs')
    if not any(e.get('event')=='session_done' and e.get('copies')==copies for e in events):raise ValueError('missing receiver completion')
    digest=hashlib.sha256(original).hexdigest()
    if not any(line.split()==[digest,REMOTE_FILE] for line in text):raise ValueError('Linux sha256sum differs/missing')
    if 'LIDAR_STATIC_REMOTE_DONE' not in text:raise ValueError('missing shell completion')
    ppp=[]
    for line in text:
        if line.strip().startswith('ppp0:'):
            values=[int(v) for v in line.split(':',1)[1].split()]
            if len(values)==16:ppp.append(values)
    delta=None
    if len(ppp)>=2:
        delta={key:ppp[-1][index]-ppp[0][index] for key,index in
          [('rx_errors',2),('rx_drop',3),('tx_errors',10),('tx_drop',11)]}
    return dict(readback_sha256=readbacks,linux_sha256=digest,events=events,remote_text=text,PPP_counter_delta=delta)


def remote_command(binary,copies,size,tag):
    sha=hashlib.sha256(binary).hexdigest();part='/tmp/lidar_rx.'+tag+'.part';q=shlex.quote
    helper=(D/'build/copy_exact').read_bytes();helper_sha=hashlib.sha256(helper).hexdigest()
    copier='/tmp/lidar_copy.'+tag;batch='/tmp/lidar_batch.'+tag
    return ("printf 'LIDAR_PREFLIGHT_BEGIN\\n'; uname -m || exit 20; "
      "printf 'LIDAR_PPP_BEFORE\\n'; cat /proc/net/dev; free; printf 'LIDAR_PREFLIGHT_OK\\n'; "
      f"/bin/busybox dd bs=1 count={len(helper)} of={q(copier)} 2>/dev/null || exit 21; "
      f"digest=$(/bin/sha256sum {q(copier)}) || exit 21; "
      f'case "$digest" in {q(helper_sha+"  "+copier)}) ;; *) exit 21;; esac; '
      f"chmod 755 {q(copier)} || exit 21; printf 'LIDAR_BOOTSTRAP_OK\\n'; "
      f"{q(copier)} 3>&1 >{q(part)} || exit 21; "
      f"digest=$(/bin/sha256sum {q(part)}) || exit 22; "
      f'case "$digest" in {q(sha+"  "+part)}) ;; '
      '*) printf \'RECEIVER_HASH_MISMATCH %s\\n\' "$digest" >&2; exit 22;; esac; '
      "printf 'LIDAR_RECEIVER_SHA_OK\\n'; "
      f"chmod 755 {q(part)} && /bin/busybox mv {q(part)} /tmp/lidar_rx || exit 23; "
      f"{q(copier)} 3>&1 >{q(batch)} || exit 21; "
      f"/tmp/lidar_rx --receive {size} {copies} {q(REMOTE_FILE)} <{q(batch)}; rc=$?; "
      'case "$rc" in 0) ;; *) exit "$rc";; esac; '
      f"/bin/busybox rm -f {q(batch)}; "
      f"/bin/sha256sum {q(REMOTE_FILE)} || exit 24; /bin/busybox wc -c {q(REMOTE_FILE)}; "
      "printf 'LIDAR_PPP_AFTER\\n'; cat /proc/net/dev; free; printf 'LIDAR_STATIC_REMOTE_DONE\\n'")


def transfer(process,helper,binary,original,copies,captured,state):
    def until(marker,stage,quiet=False):
        state['stage']=stage
        while True:
            line=process.stdout.readline()
            if not line:raise RuntimeError('SSH closed during '+stage+'; inspect retained SSH/stderr logs')
            captured.extend(line)
            if not quiet:print(line.decode(errors='replace').rstrip(),flush=True)
            if line.rstrip(b'\r\n')==marker:return
    def send_blob(data,label):
        state['stage']=label
        process.stdin.write(struct.pack('<I',len(data)));process.stdin.flush()
        until(b'LIDAR_COPY_READY',label+'_READY')
        for offset in range(0,len(data),512):
            chunk=data[offset:offset+512]
            state['stage']=label+'_BLOCK_ACK'
            process.stdin.write(chunk);process.stdin.flush()
            until(b'LIDAR_BLOCK_OK',label+'_BLOCK_ACK',quiet=True)
            done=offset+len(chunk);state[label+'_confirmed_bytes']=done
            if done%4096==0 or done==len(data):
                print(label,done,'/',len(data),'bytes confirmed by Linux',flush=True)
    until(b'LIDAR_PREFLIGHT_OK','SSH_PREFLIGHT')
    if b'riscv32' not in captured:raise RuntimeError('Remote machine is not the expected RV32 board')
    preflight=time.monotonic()
    print('SSH_REMOTE_COMMAND_PASS; uploading',len(helper),'byte bootstrap, then acknowledged 512-byte blocks...',flush=True)
    state['stage']='BOOTSTRAP_UPLOAD'
    process.stdin.write(helper);process.stdin.flush()
    until(b'LIDAR_BOOTSTRAP_OK','BOOTSTRAP_VERIFY')
    send_blob(binary,'RECEIVER_UPLOAD')
    until(b'LIDAR_RECEIVER_SHA_OK','RECEIVER_VERIFY')
    print('Receiver SHA256 verified; uploading point batch with per-block acknowledgements...',flush=True)
    send_blob(original*copies,'POINT_UPLOAD')
    state['stage']='POINT_FILE_ROUND_TRIPS'
    print('Point batch received; waiting for',copies,'saved-file round trips...',flush=True)
    process.stdin.close()
    captured.extend(process.stdout.read());process.wait()
    return preflight


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file',type=Path,default=SOURCE)
    parser.add_argument('--copies',type=int,default=3,choices=range(1,11))
    parser.add_argument('--timeout',type=int,default=900)
    parser.add_argument('--inspect',action='store_true')
    args=parser.parse_args();R.mkdir(exist_ok=True)
    original=args.file.read_bytes();expected=validate_file(original)
    if len(original)*args.copies>1024*1024:raise ValueError('Static batch exceeds 1 MiB RAM bound; reduce --copies')
    print('LOCAL_VALID',len(original),'bytes',expected['point_frames'],'point frames',expected['points'],'points',flush=True)
    if args.inspect:
        print(json.dumps(expected,indent=2));return 0
    binary=(D/'build/lidar_rx').read_bytes();manifest=json.loads((D/'build/manifest.json').read_text())
    if hashlib.sha256(binary).hexdigest()!=manifest['sha256']:raise ValueError('receiver executable manifest mismatch')
    helper=(D/'build/copy_exact').read_bytes();helper_manifest=json.loads((D/'build/copy_manifest.json').read_text())
    if hashlib.sha256(helper).hexdigest()!=helper_manifest['sha256']:raise ValueError('bootstrap executable manifest mismatch')
    tag=datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f');base=R/('static_'+tag)
    settings=ssh_config();settings[settings.index('-E')+1]=str(base)+'.ssh.log'
    command=remote_command(binary,args.copies,len(original),tag)
    state=dict(started=datetime.datetime.now().isoformat(),status='STARTED',source=str(args.file.resolve()),
      source_bytes=len(original),source_sha256=expected['sha256'],copies=args.copies,remote_file=REMOTE_FILE,
      destination='root@192.168.11.2:2222',configuration_source=str(F/'ssh_windows.ps1'),
      authentication='existing private key, known_hosts and unchanged SSH algorithm options',
      source_validation=expected,receiver_bytes=len(binary),bootstrap_bytes=len(helper),reset=False,firmware_modified=False)
    base.with_suffix('.start.json').write_text(json.dumps(state,indent=2))
    print('Connect Windows Wi-Fi to Anlu-B-Linux before running this script.',flush=True)
    print('One SSH connection; binary stdin; deployment +',args.copies,'exact saved-file round trips.',flush=True)
    print('SSH authentication previously took about 3 minutes. Keep Wi-Fi and power unchanged.',flush=True)
    print('Report:',base,flush=True)
    started=time.monotonic();process=None;captured=bytearray();timed_out=threading.Event()
    try:
        state['network']=network_preflight()
        with base.with_suffix('.stderr.log').open('wb') as errors:
            process=subprocess.Popen([*settings,command],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors)
            def expire():
                timed_out.set();process.kill()
            timer=threading.Timer(max(1,args.timeout-(time.monotonic()-started)),expire);timer.daemon=True;timer.start()
            try:
                preflight=transfer(process,helper,binary,original,args.copies,captured,state)
            finally:timer.cancel()
        full=bytes(captured);base.with_suffix('.stdout.bin').write_bytes(full)
        state.update(ssh_exit_code=process.returncode,ssh_preflight_seconds=preflight-started,
                     binary_phase_seconds=time.monotonic()-preflight,total_seconds=time.monotonic()-started)
        if process.returncode:raise RuntimeError('SSH/remote receiver failed; exit='+str(process.returncode))
        verified=parse_output(full,original,args.copies,expected)
        state.update(verified,status='PASS_STATIC_TRANSFER_AND_LINUX_VALIDATION',
                     effective_payload_bytes_per_second=len(original)*args.copies/state['binary_phase_seconds'],
                     point_frames_verified=args.copies*expected['point_frames'],application_checksum_errors=0,
                     rate_scope='payload bytes / deployment+upload+parse+readback interval, not raw UART throughput',
                     limitations='Static transfer only. Real-time COM22/5 FPS and long-duration stability not tested.')
        base.with_suffix('.remote.txt').write_text('\n'.join(verified['remote_text'])+'\n',encoding='utf8')
        (D/'build/static_acceptance.json').write_text(json.dumps(state,indent=2))
        for event in verified['events']:
            if event.get('event')=='summary':
                print('LINUX_FILE_PASS round={round} bytes={bytes} frames={frames} points={points} errors={errors}'.format(**event),flush=True)
        first=next((e for e in verified['events'] if e.get('event')=='frame'),None)
        if first:
            print('LINUX_FIRST_FRAME rx={rx} ry={ry} yaw_mrad={yaw_mrad} vy_mm_s={vy_mm_s} vx_mm_s={vx_mm_s} wz_mrad_s={wz_mrad_s} points={points}'.format(**first),flush=True)
        print('TIMING preflight=%.1fs binary_phase=%.1fs effective_payload=%.1f B/s (includes deployment, validation and readback)'%
          (state['ssh_preflight_seconds'],state['binary_phase_seconds'],state['effective_payload_bytes_per_second']),flush=True)
        print('STATIC_LIDAR_PASS',args.copies,'copies;',len(original),'bytes each; SHA256',expected['sha256'],flush=True)
        return 0
    except (Exception,KeyboardInterrupt) as error:
        if process is not None:
            if process.poll() is None:process.kill()
            # Drain even if the deadline timer already killed SSH; keep partial diagnostics.
            captured.extend(process.stdout.read());process.wait()
        base.with_suffix('.stdout.bin').write_bytes(captured)
        message=('Total deadline exceeded during '+state.get('stage','network preflight')) if timed_out.is_set() else str(error)
        if isinstance(error,BrokenPipeError) and not timed_out.is_set():
            message='SSH input pipe closed during '+state.get('stage','transfer')+'; inspect .ssh.log and .stderr.log for the remote/network cause'
        state.update(status='FAIL_OR_INTERRUPTED',error=message,ssh_exit_code=process.returncode if process else None,
                     total_seconds=time.monotonic()-started)
        print('STATIC_LIDAR_FAIL:',message,'; logs retained:',base,flush=True)
        return 1
    finally:
        state['finished']=datetime.datetime.now().isoformat()
        base.with_suffix('.json').write_text(json.dumps(state,indent=2))

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,RuntimeError) as error:
        print('ERROR:',error,file=sys.stderr);raise SystemExit(1)
