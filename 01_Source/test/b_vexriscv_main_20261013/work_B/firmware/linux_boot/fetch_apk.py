"""Cache build-host packages through the host proxy; guest apk verifies signatures."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import io,json,re,tarfile,requests
HERE=Path(__file__).resolve().parent
BASE='https://dl-cdn.alpinelinux.org/alpine/v3.22/'
packages={};providers={}
for repository in ['main','community']:
    path=HERE/f'cache/apk/v3.22/{repository}/x86_64/APKINDEX.tar.gz'
    with tarfile.open(fileobj=io.BytesIO(path.read_bytes())) as archive:
        index=archive.extractfile('APKINDEX').read().decode()
    for block in index.split('\n\n'):
        fields=dict(line.split(':',1) for line in block.splitlines() if ':' in line)
        if 'P' not in fields:continue
        fields['repo']=repository
        packages[fields['P']]=fields
        for alias in fields.get('p','').split():
            providers.setdefault(re.split(r'[<>=~]',alias)[0],fields['P'])
pending='build-base bison flex bc perl python3 clang20 llvm20 lld20 openssl-dev elfutils-dev unzip cpio xz e2fsprogs'.split()
selected={}
while pending:
    name=re.split(r'[<>=~]',pending.pop())[0]
    if name.startswith('!'):continue
    if name not in packages:name=providers.get(name,name)
    if name in selected:continue
    if name not in packages:raise ValueError('Unresolved build-host dependency: '+name)
    p=packages[name];selected[name]=p
    pending.extend(p.get('D','').split())

def fetch(p):
    filename=p['P']+'-'+p['V']+'.apk'
    path=HERE/f"cache/apk/v3.22/{p['repo']}/x86_64/{filename}"
    size=int(p['S'])
    if path.exists() and path.stat().st_size==size:return filename+' reused'
    url=BASE+p['repo']+'/x86_64/'+filename
    def chunk(start):
        end=min(start+1048576,size)-1
        for attempt in range(4):
            try:
                r=requests.get(url,headers={'Range':f'bytes={start}-{end}'},timeout=(10,20))
                r.raise_for_status()
                assert r.status_code==206 and r.headers.get('Content-Range')==f'bytes {start}-{end}/{size}' and len(r.content)==end-start+1
                return r.content
            except Exception:
                if attempt==3:raise
    with ThreadPoolExecutor(max_workers=4) as pool:data=b''.join(pool.map(chunk,range(0,size,1048576)))
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix('.partial');tmp.write_bytes(data);tmp.replace(path)
    return filename+' fetched'

if __name__=='__main__':
    print('Build host dependency closure:',len(selected),'packages',flush=True)
    with ThreadPoolExecutor(max_workers=6) as pool:
        for future in as_completed([pool.submit(fetch,p) for p in selected.values()]):print(future.result(),flush=True)
    (HERE/'cache/apk_packages.json').write_text(json.dumps(selected,indent=2))
