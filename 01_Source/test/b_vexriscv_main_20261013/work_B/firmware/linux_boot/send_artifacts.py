"""Binary-safe transfer from isolated Linux build guest to host loopback server."""
from pathlib import Path
from urllib.request import Request,urlopen
import hashlib,json
names=['Image','vmlinux','kernel.config','busybox.config','busybox',
       'rootfs.cpio.gz','tool_versions.txt','build.log']
records={}
for name in names:
    data=(Path('/build/out')/name).read_bytes()
    request=Request('http://10.0.2.2:18990/upload/'+name,data=data,method='POST',
                    headers={'Content-Type':'application/octet-stream'})
    with urlopen(request,timeout=30) as response:
        assert response.read()==b'OK\n'
    records[name]={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    print(name,records[name],flush=True)
Path('/build/out/artifact_hashes.json').write_text(json.dumps(records,indent=2))
