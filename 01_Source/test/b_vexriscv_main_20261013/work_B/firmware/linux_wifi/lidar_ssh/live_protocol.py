"""Bounded framing and latest-frame slot; no COM, SSH or board side effects."""
import threading,time
from protocol import HEADER,MAX_PAYLOAD,decode_frame

def hash32(data):
    value=2166136261
    for byte in data:value=((value^byte)*16777619)&0xffffffff
    return value

class Framer:
    def __init__(self):
        self.buffer=bytearray()
        self.stats=dict(valid=0,point_frames=0,other=0,invalid=0,checksum_errors=0,length_errors=0,discarded_bytes=0)

    def feed(self,data):
        self.buffer.extend(data);frames=[]
        while True:
            index=self.buffer.find(HEADER)
            if index<0:
                keep=1 if self.buffer.endswith(b'\xaa') else 0
                self.stats['discarded_bytes']+=len(self.buffer)-keep
                if keep:self.buffer[:]=b'\xaa'
                else:self.buffer.clear()
                break
            self.stats['discarded_bytes']+=index;del self.buffer[:index]
            if len(self.buffer)<4:break
            length=int.from_bytes(self.buffer[2:4],'little')
            if not 1<=length<=MAX_PAYLOAD:
                self.stats['length_errors']+=1;self.stats['invalid']+=1
                self.stats['discarded_bytes']+=1;del self.buffer[:1];continue
            if len(self.buffer)<length+5:break
            raw=bytes(self.buffer[:length+5])
            try:fields=decode_frame(raw)
            except ValueError as error:
                self.stats['invalid']+=1
                if 'XOR' in str(error):self.stats['checksum_errors']+=1
                self.stats['discarded_bytes']+=1;del self.buffer[:1];continue
            del self.buffer[:length+5];self.stats['valid']+=1
            if fields['type']==2:
                self.stats['point_frames']+=1;frames.append((raw,fields))
            else:self.stats['other']+=1
        return frames

class LatestFrame:
    def __init__(self):
        self.condition=threading.Condition();self.item=None;self.replaced=0

    def put(self,item):
        with self.condition:
            if self.item is not None:self.replaced+=1
            self.item=item;self.condition.notify()

    def take(self,timeout):
        with self.condition:
            if self.item is None:self.condition.wait(timeout)
            item=self.item;self.item=None;return item

def verify_ack(event,raw,fields,sequence):
    if event.get('event')!='frame' or event.get('seq')!=sequence:raise ValueError('Linux frame acknowledgement sequence')
    if any(event.get(k)!=v for k,v in fields.items()):raise ValueError('Linux decoded fields differ from transmitted frame')
    if event.get('hash32')!=hash32(raw):raise ValueError('Linux full-frame hash differs')
    if any(event.get(k)!=0 for k in ['checksum_errors','length_errors','field_errors']):raise ValueError('Linux receiver reported invalid frames')

def rate_wait(last_sent,now):
    return max(0,last_sent+.2-now)

def wait_rate(last_sent):
    while True:
        delay=rate_wait(last_sent,time.perf_counter())
        if delay<=0:return
        time.sleep(delay)
