"""Loopback-only build input server and bounded guest artifact receiver."""
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import re, requests
from concurrent.futures import ThreadPoolExecutor

HERE = Path(__file__).resolve().parent
OUT = HERE / 'build'
OUT.mkdir(exist_ok=True)
ARTIFACTS = {'Image', 'vmlinux', 'kernel.config', 'busybox.config', 'busybox',
             'rootfs.cpio.gz', 'build.log', 'tool_versions.txt', 'verilator.log',
             'verilator_build.log', 'artifact_hashes.json'}

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(HERE), **kwargs)

    def do_GET(self):
        if self.path.startswith('/apk/'):
            # The guest has no direct Internet route. Reuse the host's configured
            # proxy; apk still verifies the Alpine index and package signatures.
            if not re.fullmatch(r'/apk/v3\.22/(main|community)/x86_64/[A-Za-z0-9_.+\-]+',self.path):
                self.send_error(400)
                return
            try:
                cached=HERE/'cache'/self.path.lstrip('/')
                if not cached.exists():
                    url='https://dl-cdn.alpinelinux.org/alpine/'+self.path[5:]
                    r=requests.get(url,headers={'Range':'bytes=0-0'},timeout=(15,20))
                    r.raise_for_status()
                    if r.status_code==206:
                        size=int(r.headers['Content-Range'].split('/')[-1])
                        def chunk(start):
                            end=min(start+1048576,size)-1
                            for attempt in range(3):
                                try:
                                    q=requests.get(url,headers={'Range':f'bytes={start}-{end}'},timeout=(15,30))
                                    q.raise_for_status()
                                    if q.status_code!=206 or q.headers.get('Content-Range')!=f'bytes {start}-{end}/{size}' or len(q.content)!=end-start+1:
                                        raise ValueError('Invalid package range response')
                                    return q.content
                                except (requests.RequestException,ValueError):
                                    if attempt==2:raise
                        with ThreadPoolExecutor(max_workers=8) as pool:
                            data=b''.join(pool.map(chunk,range(0,size,1048576)))
                    else:
                        data=r.content
                    cached.parent.mkdir(parents=True,exist_ok=True)
                    temporary=cached.with_suffix('.partial')
                    temporary.write_bytes(data)
                    temporary.replace(cached)
                data=cached.read_bytes()
                self.send_response(200)
                self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (requests.RequestException,OSError,ValueError) as error:
                self.log_error('%s: %s',type(error).__name__,str(error))
                self.send_error(502)
            return
        super().do_GET()

    def do_POST(self):
        name = self.path.removeprefix('/upload/')
        length = int(self.headers.get('Content-Length', '-1'))
        if self.path != '/upload/' + name or name not in ARTIFACTS or not 0 < length <= 64*1024*1024:
            self.send_error(400)
            return
        data = self.rfile.read(length)
        if len(data) != length:
            self.send_error(400)
            return
        partial = OUT / (name + '.partial')
        partial.write_bytes(data)
        partial.replace(OUT / name)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'OK\n')

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18990), Handler).serve_forever()
