"""Bounded loopback SMTP peer for synthetic tests only. No real credentials/data."""
import os, socket, ssl, subprocess, sys, threading
os.umask(0o077)
root, mode = sys.argv[1:3]
cert, key = root + '/cert.pem', root + '/key.pem'
subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',key,'-out',cert,'-subj','/CN=localhost','-days','1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(cert, key)
listener = socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(4)
print(listener.getsockname()[1], flush=True)
def serve(raw):
    try:
        conn = raw if mode == 'missing-starttls' else context.wrap_socket(raw, server_side=True)
        with conn:
            conn.settimeout(12); stream = conn.makefile('rb')
            def send(value): conn.sendall(value.encode())
            send('220 localhost synthetic SMTP\r\n')
            while True:
                line = stream.readline(16384)
                if not line: return
                text = line.decode().rstrip('\r\n'); upper = text.upper()
                with open(root + '/commands.txt','a') as log: log.write(('AUTH [redacted]' if upper.startswith('AUTH') else text) + '\n')
                if upper.startswith('EHLO'):
                    send('250-localhost\r\n250-AUTH PLAIN\r\n250 SIZE ' + ('100' if mode == 'size' else '30000000') + '\r\n')
                elif upper.startswith('AUTH PLAIN'): send('235 2.7.0 authenticated\r\n')
                elif upper.startswith('MAIL FROM'): send('250 sender accepted\r\n')
                elif upper.startswith('RCPT TO'):
                    send('550 recipient rejected\r\n' if mode == 'reject-recipient' and 'BCC@' in upper else '250 recipient accepted\r\n')
                elif upper == 'DATA':
                    send('354 send message\r\n'); body = bytearray()
                    while True:
                        part = stream.readline(65536)
                        if not part: return
                        if part == b'.\r\n': break
                        if part.startswith(b'..'): part = part[1:]
                        body.extend(part)
                        if len(body) > 30000000: return
                    with open(root + '/message.eml','wb') as message: message.write(body)
                    if mode == 'ambiguous': return
                    send('550 message rejected\r\n' if mode == 'reject-content' else '250 2.0.0 accepted synthetic\r\n')
                elif upper == 'RSET': send('250 reset\r\n')
                elif upper == 'QUIT': send('221 bye\r\n'); return
                else: send('500 unsupported synthetic command\r\n')
    except (OSError, ssl.SSLError): pass
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve,args=(connection,),daemon=True).start()
