"""Fetch pinned build inputs locally; validate hashes before extracting/running."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib, json, requests

HERE = Path(__file__).resolve().parent
CACHE = HERE / 'cache'
CACHE.mkdir(exist_ok=True)
INPUTS = [
    ('qemu-w64-setup-20250422.exe', 'https://qemu.weilnetz.de/w64/2025/',
     'sha512', '1db9a723e241547a0c63fddbc52dca2d39c3c7d4e0c205019c931d33e2f9e8cc476522b4d3303e8586e67c58ae757a594911cf511aa21bacea7d4f2e56f99e77'),
    ('alpine-virt-3.22.2-x86_64.iso', 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/',
     'sha256', 'b6c45d69829b1b0416ada798353805099d57b8bef9093b85a8319fe5373595d5'),
    ('linux-6.12.58.tar.xz', 'https://cdn.kernel.org/pub/linux/kernel/v6.x/',
     'sha256', '5f1c4c546660a6a81046fdfa6195306bad2c8d17c0d69876dc100a85ad4613ac'),
    ('busybox-1.36.1.tar.bz2', 'https://busybox.net/downloads/',
     'sha256', 'b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314'),
    ('musl-1.2.5.tar.gz', 'https://sources.buildroot.net/musl/',
     'sha256', 'a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4'),
    ('ziglang-0.13.0-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.musllinux_1_1_x86_64.whl',
     'https://mirrors.aliyun.com/pypi/packages/0c/b7/ecfdce6368cc3664d301f7f52db4fe1004aa7da7a12c4a9bf1de534ff6ab/',
     'sha256', '3ce0c9f16547e5d61b32e0d226926e9a2552ef4b91fccf7ab5ea1a623a77824b'),
]

def fetch(record):
    name, base, algorithm, digest = record
    target = CACHE / name
    if target.exists() and hashlib.new(algorithm, target.read_bytes()).hexdigest() == digest:
        print('Reused', name, flush=True)
        return
    partial = target.with_suffix(target.suffix + '.partial')
    response = requests.get(base + name, headers={'Range': 'bytes=0-0'}, timeout=(15, 20))
    response.raise_for_status()
    assert response.status_code == 206, 'Server must support bounded range requests'
    total = int(response.headers['Content-Range'].split('/')[-1])
    block_size = 1024 * 1024
    def block(start):
        stop = min(start + block_size, total) - 1
        for attempt in range(4):
            try:
                r = requests.get(base + name, headers={'Range': f'bytes={start}-{stop}'}, timeout=(15, 30))
                r.raise_for_status()
                assert r.status_code == 206 and r.headers.get('Content-Range') == f'bytes {start}-{stop}/{total}'
                assert len(r.content) == stop - start + 1
                return start, r.content
            except Exception:
                if attempt == 3:
                    raise
    existing = partial.read_bytes() if partial.exists() and partial.stat().st_size == total else b''
    # Reuse completed range blocks; the final full-file digest remains mandatory.
    starts = [i for i in range(0, total, block_size) if not any(existing[i:i+1024])]
    with partial.open('r+b' if existing else 'wb') as out, ThreadPoolExecutor(max_workers=16) as pool:
        out.truncate(total)
        futures = [pool.submit(block, i) for i in starts]
        for count, future in enumerate(as_completed(futures), 1):
            start, data = future.result()
            out.seek(start)
            out.write(data)
            out.flush()
            if count % 16 == 0:
                print(name, 'new blocks', count, '/', len(starts), flush=True)
    assert hashlib.new(algorithm, partial.read_bytes()).hexdigest() == digest, 'Hash mismatch: ' + name
    partial.replace(target)
    print('Verified', name, target.stat().st_size, flush=True)

if __name__ == '__main__':
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(fetch, INPUTS))
    (CACHE / 'inputs.json').write_text(json.dumps(INPUTS, indent=2))
