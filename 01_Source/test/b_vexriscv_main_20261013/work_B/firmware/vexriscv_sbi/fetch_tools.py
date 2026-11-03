"""Fetch portable, hash-checked tools locally; no PATH/registry/OS installation."""
from pathlib import Path
import hashlib,json,tarfile,urllib.request,zipfile
from concurrent.futures import ThreadPoolExecutor
import zstandard
HERE=Path(__file__).resolve().parent
ROOT=HERE/'toolchain';ROOT.mkdir(exist_ok=True)
def fetch(url,digest):
    path=ROOT/url.rsplit('/',1)[-1]
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
        print('Downloading '+url,flush=True)
        # This network stalls full-file responses; bounded Range requests work.
        req=urllib.request.Request(url,headers={'Range':'bytes=0-0'})
        with urllib.request.urlopen(req,timeout=30) as response:
            size=int(response.headers['Content-Range'].split('/')[-1])
        block=1024*1024
        def chunk(start):
            end=min(start+block,size)-1
            req=urllib.request.Request(url,headers={'Range':f'bytes={start}-{end}'})
            with urllib.request.urlopen(req,timeout=30) as response:
                assert response.headers['Content-Range']==f'bytes {start}-{end}/{size}'
                data=response.read()
            assert len(data)==end-start+1
            return data
        with ThreadPoolExecutor(max_workers=4) as pool,path.open('wb') as output:
            for data in pool.map(chunk,range(0,size,block)):output.write(data)
    assert hashlib.sha256(path.read_bytes()).hexdigest()==digest,path
    return path
zig_url='https://mirrors.aliyun.com/pypi/packages/e0/0c/66f4710aedf5544e15779ff9c6e770322986e15daf9299b1a4df0be19e09/ziglang-0.13.0-py3-none-win_amd64.whl'
zig_sha='b64b2aa936ebbfeecfbb2611df331a5474edebe1246b98c2f56d6ae4d58b71fc'
# Official download host stalled; use the pinned PyPI binary distribution.
p=fetch(zig_url,zig_sha)
if not (ROOT/'ziglang/zig.exe').exists():
    with zipfile.ZipFile(p) as archive:
        for name in archive.namelist():
            assert (ROOT/name).resolve().is_relative_to(ROOT.resolve())
        archive.extractall(ROOT)
packages=[('dtc','1.8.1-1','8f08b21b7b932b193337d005c8c04732f678dac9e89dcd163eafda167af40d7c'),
          ('libyaml','0.2.5-2','81cd4032639f5e6ec93803756f3d203d44a2b98a1fc2094f68470dc18098bd9d')]
records=[dict(name='Zig 0.13.0 (ziglang PyPI distribution)',url=zig_url,sha256=zig_sha)]
for name,version,digest in packages:
    url=f'https://mirrors.tuna.tsinghua.edu.cn/msys2/mingw/mingw64/mingw-w64-x86_64-{name}-{version}-any.pkg.tar.zst'
    p=fetch(url,digest)
    with p.open('rb') as raw,zstandard.ZstdDecompressor().stream_reader(raw) as reader:
        with tarfile.open(fileobj=reader,mode='r|') as archive:
            for member in archive:
                if member.isfile() and member.name.startswith('mingw64/'):
                    target=ROOT/member.name
                    assert target.resolve().is_relative_to(ROOT.resolve())
                    target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_bytes(archive.extractfile(member).read())
    records.append(dict(name=name+' '+version,url=url,sha256=digest))
(ROOT/'provenance.json').write_text(json.dumps(records,indent=2))
print('Portable tools ready',flush=True)
