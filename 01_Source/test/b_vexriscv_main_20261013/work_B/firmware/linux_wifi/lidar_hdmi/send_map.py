"""Use the verified existing serial/SSH sender with the isolated HDMI receiver binary."""
import json,socket,sys,time
from pathlib import Path
D=Path(__file__).resolve().parent;F=D.parent;R=F.parents[1]/'reports/lidar_hdmi_20261025'

def wait_for_linux(check_network,timeout=900):
    network=check_network();started=time.monotonic();deadline=started+timeout;next_status=started
    print('Waiting for Linux TCP 192.168.11.2:2222 (up to 15 minutes). Keep B/ESP powered and stay on Anlu-B-Linux; COM15 is not required.',flush=True)
    while True:
        now=time.monotonic()
        if now>=deadline:raise TimeoutError('Linux TCP is still unreachable; check B-board boot and the ESP PPP link before retrying.')
        try:
            with socket.create_connection(('192.168.11.2',2222),timeout=min(3,deadline-now)) as connection:
                connection.getpeername()
        except OSError:
            network=check_network()
            now=time.monotonic()
            if now>=next_status:
                print('WAIT_LINUX_TCP %.0fs; Wi-Fi connected, Linux TCP not ready yet.'%(now-started),flush=True)
                next_status=now+30
            time.sleep(min(5,max(0,deadline-now)))
        else:
            elapsed=time.monotonic()-started
            print('LINUX_TCP_REACHABLE after %.1fs; starting SSH authentication...'%elapsed,flush=True)
            return dict(network,linux_tcp_wait_seconds=elapsed)

def main():
    sys.path.insert(0,str(F/'lidar_ssh'));import send_live
    (R/'board').mkdir(parents=True,exist_ok=True)
    print('Requires NEW camera_to_dsi_display_lidar FPGA bit AND the new lidarmap Linux kernel.',flush=True)
    print('Old Flash/ESP remain separate. This script does not synthesize, flash, or reset.',flush=True)
    print('Map: HDMI x=1063..1263, y=240..440; white points, green robot, yellow heading.',flush=True)
    print('APPROX semantic mapping: assumed 60-degree forward cameras, no calibrated offsets; nearest point in horizontal bbox may belong to another object. Labels expire after 120 video frames.',flush=True)
    send_live.D=D;send_live.R=R/'board'
    original_verify=send_live.verify_ack
    def verify_display(event,raw,fields,seq):
        original_verify(event,raw,fields,seq)
        if event.get('display_frame_id')!=seq:
            raise ValueError('HDMI displayed frame ID does not match the received point frame')
    send_live.verify_ack=verify_display
    original_network=send_live.network_preflight
    send_live.network_preflight=lambda:wait_for_linux(original_network)
    before=set((R/'board').glob('live_*.json'))
    try:return send_live.main()
    finally:
        send_live.network_preflight=original_network
        for path in set((R/'board').glob('live_*.json'))-before:
            state=json.loads(path.read_text())
            state.update(display_ack='MMIO displayed frame ID checked for every acknowledged frame',
              limits='Maximum 5 FPS; actual rate measured. New lidar FPGA/kernel required. Frame ID proves the peripheral swap handshake, not physical HDMI image quality.')
            path.write_text(json.dumps(state,indent=2))

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,RuntimeError) as error:print('ERROR:',error,file=sys.stderr);raise SystemExit(1)
