import os,socket,struct,time,hashlib
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes

def probe(host,port,secret,timeout=12):
    raw=bytes.fromhex(secret)
    if len(raw)==17 and raw[0]==0xdd: raw=raw[1:]
    assert len(raw)==16
    while True:
        header=bytearray(os.urandom(64))
        if header[0]!=0xef and header[:4] not in [b'HEAD',b'POST',b'GET ',b'OPTI',b'\xee'*4,b'\xdd'*4] and header[4:8]!=b'\0'*4: break
    header[56:60]=b'\xdd'*4
    header[60:62]=struct.pack('<h',2)
    rev=bytes(header[::-1])
    enc=Cipher(algorithms.AES(hashlib.sha256(bytes(header[8:40])+raw).digest()),modes.CTR(bytes(header[40:56]))).encryptor()
    dec=Cipher(algorithms.AES(hashlib.sha256(rev[8:40]+raw).digest()),modes.CTR(rev[40:56])).decryptor()
    encrypted=enc.update(bytes(header))
    wire=bytes(header[:56])+encrypted[56:]
    nonce=os.urandom(16)
    body=struct.pack('<I',0xbe7e8ef1)+nonce
    message=b'\0'*8+struct.pack('<Q',int(time.time()*2**32)&~3)+struct.pack('<I',len(body))+body
    message+=os.urandom(8)
    with socket.create_connection((host,port),timeout=timeout) as sock:
        sock.settimeout(timeout);sock.sendall(wire+enc.update(struct.pack('<I',len(message))+message))
        def receive(n):
            out=b''
            while len(out)<n:
                piece=sock.recv(n-len(out))
                if not piece: raise EOFError('MTProto peer closed')
                out+=piece
            return dec.update(out)
        length=struct.unpack('<I',receive(4))[0]
        if not 40<=length<=65536: raise ValueError('Invalid MTProto response size')
        payload=receive(length)
        assert payload[:8]==b'\0'*8 and payload[20:24]==struct.pack('<I',0x05162463) and payload[24:40]==nonce,'Invalid resPQ/nonce'
    return True
