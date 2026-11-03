"""Isolated portable Linux build VM, using only a new local virtual disk."""
from pathlib import Path
import hashlib, json, socket, subprocess, sys, time
from fetch import INPUTS

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REPORT = ROOT / 'reports/linux_boot_20261020'
CACHE = HERE / 'cache'
QEMU = HERE / 'tools/qemu'
SEVEN = Path('C:/Program Files/NVIDIA Corporation/NVIDIA app/7z.exe')
ISO = CACHE / 'alpine-virt-3.22.2-x86_64.iso'
NO_WINDOW = 0x08000000

def run(args):
    subprocess.run(list(map(str, args)), check=True, creationflags=NO_WINDOW)

def prepare():
    for name,base,algorithm,digest in INPUTS[:2]:
        assert hashlib.new(algorithm,(CACHE/name).read_bytes()).hexdigest()==digest,name
    if not (QEMU / 'qemu-system-x86_64.exe').exists():
        QEMU.mkdir(parents=True, exist_ok=True)
        run([SEVEN, 'x', CACHE / 'qemu-w64-setup-20250422.exe', '-o'+str(QEMU), '-x!*.nsis', '-y'])
    boot = HERE / 'tools/alpine'
    if not (boot / 'boot/vmlinuz-virt').exists():
        run([SEVEN, 'x', ISO, 'boot/vmlinuz-virt', 'boot/initramfs-virt', '-o'+str(boot), '-y'])
    disk = CACHE / 'builder.qcow2'
    if not disk.exists():
        run([QEMU / 'qemu-img.exe', 'create', '-f', 'qcow2', disk, '8G'])
    return boot, disk

def start():
    boot, disk = prepare()
    server_log = open(REPORT / 'http.log', 'ab')
    server = subprocess.Popen([sys.executable, str(HERE / 'host_server.py')],
                              stdout=server_log, stderr=server_log, creationflags=NO_WINDOW)
    args = [str(QEMU / 'qemu-system-x86_64.exe'), '-machine', 'q35',
            '-accel', 'whpx', '-accel', 'tcg,thread=multi', '-smp', '4', '-m', '4096',
            '-display', 'none', '-monitor', 'none',
            '-serial', 'tcp:127.0.0.1:18991,server=on,wait=off',
            '-kernel', str(boot / 'boot/vmlinuz-virt'),
            '-initrd', str(boot / 'boot/initramfs-virt'),
            '-append', 'console=ttyS0,115200 modules=loop,squashfs,sd-mod,usb-storage',
            '-cdrom', str(ISO), '-drive', 'file='+str(disk)+',if=virtio,format=qcow2',
            '-nic', 'user,model=virtio-net-pci']
    log = open(REPORT / 'builder_qemu.log', 'ab')
    vm = subprocess.Popen(args, stdout=log, stderr=log, creationflags=NO_WINDOW)
    (REPORT / 'builder_processes.json').write_text(json.dumps(
        dict(vm=vm.pid, server=server.pid, command=args), indent=2))
    deadline = time.monotonic()+120
    sock = None
    while time.monotonic()<deadline:
        if vm.poll() is not None:
            raise RuntimeError('Build VM exited; inspect builder_qemu.log')
        try:
            sock=socket.create_connection(('127.0.0.1',18991),timeout=2)
            break
        except OSError:
            time.sleep(1)
    if sock is None:
        raise TimeoutError('Build VM serial socket')
    sock.settimeout(1)
    output=bytearray()
    with open(REPORT / 'builder_serial.log','ab',buffering=0) as out:
        while time.monotonic()<deadline:
            try:
                data=sock.recv(65536)
            except socket.timeout:
                continue
            if not data:
                raise RuntimeError('Build VM serial disconnected')
            output.extend(data);out.write(data)
            if b'login:' in output:
                sock.sendall(b'root\n')
                print('Portable build VM reached root login',flush=True)
                break
    sock.close()

if __name__ == '__main__':
    start()
