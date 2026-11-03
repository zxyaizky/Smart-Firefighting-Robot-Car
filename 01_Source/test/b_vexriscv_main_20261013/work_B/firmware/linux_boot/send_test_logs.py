from pathlib import Path
from urllib.request import Request,urlopen
for name in ['verilator.log','verilator_build.log']:
    data=(Path('/build/out')/name).read_bytes()
    with urlopen(Request('http://10.0.2.2:18990/upload/'+name,data=data,method='POST'),timeout=20) as r:
        assert r.read()==b'OK\n'
