"""Persistent WEB carrier and obfuscated MTProto stream; never logs credentials."""
import base64,hashlib,hmac,http.client,os,re,struct,time
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes

def frame(kind,sid=0,payload=b''):
 return bytes([kind])+sid.to_bytes(3,'big')+len(payload).to_bytes(4,'big')+payload

class WebProbe:
 def __init__(self,secret,domain,host=None,port=443,tls=True):
  self.domain=domain;self.host=host or domain;self.port=port;self.tls=tls;self.token='';self.seq=0;self.cursor='0';self.buf=b''
  cap=base64.urlsafe_b64encode(hmac.new(bytes.fromhex(secret),b'tdesktop-web-proxy-bridge-v1\n'+domain.encode(),hashlib.sha256).digest()).decode().rstrip('=')
  status,headers,body=self.request('GET','/?bridge='+cap)
  match=re.search(rb'bootstrap="([A-Za-z0-9_-]{43})"',body)
  assert status==200 and match,'bridge not returned'
  self.token=match[1].decode()
  status,headers,body=self.request('POST','/api/v1/session',frame(16,payload=b'\1'))
  assert status==200 and body==frame(17),'session not created'
  self.token=headers['x-session-token']
  raw=bytes.fromhex(secret)
  while True:
   header=bytearray(os.urandom(64))
   if header[0]!=0xef and header[:4] not in [b'HEAD',b'POST',b'GET ',b'OPTI',b'\xee'*4,b'\xdd'*4] and header[4:8]!=b'\0'*4:break
  header[56:60]=b'\xdd'*4;header[60:62]=struct.pack('<h',2);rev=bytes(header[::-1])
  self.enc=Cipher(algorithms.AES(hashlib.sha256(bytes(header[8:40])+raw).digest()),modes.CTR(bytes(header[40:56]))).encryptor()
  self.dec=Cipher(algorithms.AES(hashlib.sha256(rev[8:40]+raw).digest()),modes.CTR(rev[40:56])).decryptor()
  encrypted=self.enc.update(bytes(header));wire=bytes(header[:56])+encrypted[56:]
  self.up(frame(1,1)+frame(2,1,wire))
 def request(self,method,path,body=None,extra=None):
  c=(http.client.HTTPSConnection if self.tls else http.client.HTTPConnection)(self.host,self.port,timeout=35)
  headers={'Host':self.domain}
  if self.token:headers['Authorization']='Bearer '+self.token
  if body is not None:headers['Content-Type']='application/octet-stream'
  headers.update(extra or {})
  try:
   c.request(method,path,body,headers);r=c.getresponse();return r.status,dict((k.lower(),v) for k,v in r.getheaders()),r.read()
  finally:c.close()
 def up(self,body):
  self.seq+=1
  status,h,b=self.request('POST','/api/v1/up',body,{'X-Up-Seq':str(self.seq)})
  assert status==204 and h.get('x-up-ack')==str(self.seq),'up failed'
 def receive(self,n):
  deadline=time.monotonic()+45
  while len(self.buf)<n:
   assert time.monotonic()<deadline,'down timeout'
   status,h,b=self.request('POST','/api/v1/down',extra={'X-Down-Cursor':self.cursor})
   assert status==200,'down failed'
   self.cursor=h['x-down-cursor']
   while b:
    kind=b[0];sid=int.from_bytes(b[1:4],'big');length=int.from_bytes(b[4:8],'big');payload=b[8:8+length];b=b[8+length:]
    if sid==1 and kind==3:raise RuntimeError('existing stream closed')
    if sid==1 and kind==2:self.buf+=self.dec.update(payload)
  result=self.buf[:n];self.buf=self.buf[n:];return result
 def exchange(self):
  nonce=os.urandom(16);body=struct.pack('<I',0xbe7e8ef1)+nonce
  message=b'\0'*8+struct.pack('<Q',int(time.time()*2**32)&~3)+struct.pack('<I',len(body))+body+os.urandom(8)
  self.up(frame(2,1,self.enc.update(struct.pack('<I',len(message))+message)))
  length=struct.unpack('<I',self.receive(4))[0];assert 40<=length<=65536,'bad MT length'
  payload=self.receive(length)
  assert payload[:8]==b'\0'*8 and payload[20:24]==struct.pack('<I',0x05162463) and payload[24:40]==nonce,'bad MT nonce/resPQ'
  return True
 def close(self):
  if self.token:self.request('DELETE','/api/v1/session');self.token=''
