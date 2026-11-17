"""Scripted synthetic IMAP peer for tests ONLY. Not a production protocol parser."""
import json, os, re, shlex, socket, ssl, subprocess, sys, threading, base64
os.umask(0o077)
root, mode = sys.argv[1:3]
cert, key = root + '/cert.pem', root + '/key.pem'
subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',key,'-out',cert,'-subj','/CN=localhost','-days','1'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version=ssl.TLSVersion.TLSv1_2
context.load_cert_chain(cert,key)
listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(8)
print(listener.getsockname()[1],flush=True)
lock=threading.Lock()
def state():
    with open(root+'/state.json') as f: return json.load(f)
def save(data):
    path=root+'/state-new.json'
    with open(path,'w') as f: json.dump(data,f)
    os.replace(path,root+'/state.json')
def record(command):
    if 'LOGIN' in command.upper() or 'AUTHENTICATE' in command.upper(): command='LOGIN [redacted]'
    with lock, open(root+'/commands.txt','a') as f: f.write(command+'\n')
def caps(data): return 'IMAP4rev1' + (' UIDPLUS MOVE' if data.get('move',True) else ' UIDPLUS') + (' ESEARCH' if data.get('esearch') else '')
def mailbox(data,selected): return data.get('mailboxes',{}).get(selected,data)
def numbers(value):
    result=set()
    for part in value.split(','):
        ends=part.split(':'); result.update(range(int(ends[0]),int(ends[-1])+1))
    return result
inline_png=b'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPYm2zwHwAFgQJQmStAeQAAAABJRU5ErkJggg=='
def body(uid,html=False,inline=False,large=False):
    if html: return (f'<h1>Fixture HTML {uid}</h1><p>Umlaut: äöü</p><img src="https://example.invalid/pixel"><script>window.bad=true</script>'+('<img src="cid:logo@mail">' if inline else '')+('<p>'+'mail '*60000+'</p>' if large else '')).encode()
    return f'Synthetic message body {uid}.\r\n'.encode()
def serve(raw):
    try:
        conn=raw if mode=='missing-starttls' else context.wrap_socket(raw,server_side=True)
        with conn:
            conn.settimeout(15); f=conn.makefile('rb'); selected='INBOX'
            def send(s): conn.sendall(s.encode() if isinstance(s,str) else s)
            send('* OK [CAPABILITY '+caps(state())+'] Synthetic fixture\r\n')
            while True:
                line=f.readline(16384)
                if not line: return
                # Only bounded synthetic search literals; the production client uses SwiftMail's encoder.
                while (literal := re.search(rb'\{(\d+)(\+)?\}\r\n$',line)):
                    size=int(literal[1])
                    if size>8192: return
                    if not literal[2]: send('+ ready\r\n')
                    value=f.read(size)
                    line=line[:literal.start()]+b'"'+value.replace(b'\\',b'\\\\').replace(b'"',b'\\"')+b'"'+f.readline(16384)
                text=line.decode().rstrip('\r\n'); tag,command=text.split(' ',1); record(command); upper=command.upper(); data=state()
                box=mailbox(data,selected); uids=box.get('uids',[11,12]); validity=box.get('validity',data.get('validity',7)); seen=box.get('seen',[]); flagged=box.get('flagged',[])
                def flags(uid): return ' '.join(([r'\Seen'] if uid in seen else [])+([r'\Flagged'] if uid in flagged else [])+box.get('keywords',[]))
                if upper.startswith('CAPABILITY'): send('* CAPABILITY '+caps(data)+'\r\n')
                elif upper.startswith('LOGIN'):
                    if data.get('auth_fail'): send(tag+' NO Authentication rejected\r\n'); continue
                elif upper.startswith('LIST'):
                    for name,attrs in [('INBOX',r'\HasNoChildren'),('Sent',r'\Sent \HasNoChildren'),('Archive',r'\Archive'),('Trash',r'\Trash'),('Entw&APw-rfe',r'\HasNoChildren')]: send(f'* LIST ({attrs}) "/" "{name}"\r\n')
                elif upper.startswith('EXAMINE') or (upper.startswith('SELECT') and data.get('writes')):
                    if data.get('disconnect'): return
                    selected=shlex.split(command)[1]; box=mailbox(data,selected); uids=box.get('uids',[11,12]); validity=box.get('validity',data.get('validity',7))
                    send(f'* FLAGS (\\Seen \\Flagged)\r\n* {len(uids)} EXISTS\r\n* 0 RECENT\r\n')
                    send(f'* OK [UIDVALIDITY {validity}] stable\r\n* OK [UIDNEXT {max(uids,default=0)+1}] next\r\n')
                    access='READ-ONLY' if upper.startswith('EXAMINE') or data.get('read_only') else 'READ-WRITE'
                    send(tag+' OK ['+access+'] selection completed\r\n'); continue
                elif upper.startswith('UID STORE') and data.get('writes'):
                    ids=numbers(command.split()[2]); flag='seen' if r'\SEEN' in upper else 'flagged'; adding='+FLAGS' in upper
                    with lock:
                        data=state(); box=mailbox(data,selected)
                        values=set(box.get(flag,[]))
                        if not data.get('ignore_store'): values=values|ids if adding else values-ids
                        box[flag]=sorted(values); save(data)
                    if data.get('drop_after_store'): return
                elif upper.startswith('UID MOVE') and data.get('writes') and data.get('move',True):
                    parts=shlex.split(command); ids=numbers(parts[2]); target=parts[3]
                    with lock:
                        data=state(); boxes=data.setdefault('mailboxes',{})
                        if selected not in boxes: boxes[selected]={'uids':data.get('uids',[11,12]),'validity':data.get('validity',7),'seen':data.get('seen',[]),'flagged':data.get('flagged',[])}
                        source=boxes[selected]; destination=boxes.setdefault(target,{'uids':[],'validity':70,'seen':[],'flagged':[]})
                        pairs=[]
                        for uid in sorted(ids.intersection(source['uids'])):
                            new=max(destination['uids'],default=200)+1; destination['uids'].append(new); pairs.append((uid,new)); source['uids'].remove(uid)
                            for flag in ['seen','flagged']:
                                if uid in source.get(flag,[]): source[flag].remove(uid); destination.setdefault(flag,[]).append(new)
                        save(data)
                    if data.get('drop_after_move'): return
                    if pairs and not data.get('move_nomap'):
                        source_ids=','.join(str(a) for a,b in pairs); target_ids=','.join(str(b) for a,b in pairs)
                        send(tag+f' OK [COPYUID {destination["validity"]} {source_ids} {target_ids}] MOVE completed\r\n')
                    else: send(tag+' OK MOVE completed\r\n')
                    continue
                elif upper.startswith('UID SEARCH'):
                    if data.get('search_stall'): f.readline(); return
                    interval=re.search(r'\bUID (\d+):(\d+)',upper)
                    if not interval: send(tag+' BAD bounded UID interval required\r\n'); continue
                    low,high=map(int,interval.groups())
                    matches=[u for u in uids if low<=u<=high and u in box.get('search_uids',uids)]
                    if re.search(r'\bUNSEEN\b',upper): matches=[u for u in matches if u not in seen]
                    elif re.search(r'\bSEEN\b',upper): matches=[u for u in matches if u in seen]
                    if re.search(r'\bUNFLAGGED\b',upper): matches=[u for u in matches if u not in flagged]
                    elif re.search(r'\bFLAGGED\b',upper): matches=[u for u in matches if u in flagged]
                    if data.get('esearch'):
                        if data.get('search_bad_range'): send(f'* ESEARCH (TAG "{tag}") UID ALL 1:4294967295 COUNT 4294967295\r\n')
                        elif matches: send(f'* ESEARCH (TAG "{tag}") UID ALL '+','.join(map(str,matches))+f' COUNT {len(matches)} MIN {min(matches)} MAX {max(matches)}\r\n')
                        else: send(f'* ESEARCH (TAG "{tag}") UID COUNT 0\r\n')
                    else: send('* SEARCH'+(' '+' '.join(map(str,matches)) if matches else '')+'\r\n')
                    if data.get('search_change_validity'):
                        with lock:
                            data=state(); mailbox(data,selected)['validity']=validity+1; save(data)
                elif upper.startswith('FETCH') or upper.startswith('UID FETCH'):
                    if data.get('stall'): f.readline(); return
                    is_uid=upper.startswith('UID '); ids=numbers(command.split()[2 if is_uid else 1]); chosen=[(i+1,u) for i,u in enumerate(uids) if (u if is_uid else i+1) in ids]
                    for seq,uid in chosen:
                        partial=re.search(r'BODY\.PEEK\[([0-9.]+)\]<(\d+)\.(\d+)>',upper)
                        if partial:
                            html=data.get('html_only') or (data.get('html') and partial[1]=='2')
                            content=body(uid,html,data.get('inline'),data.get('large_html'))
                            if partial[1]=='2' and not data.get('html') and not data.get('html_only'):
                                content=base64.b64encode(b'x'*data.get('attachment_bytes',32))
                                if data.get('attachment_bad_encoding'): content=b'%%%invalid%%%'
                                if data.get('attachment_drop') and int(partial[2])>0: return
                            if data.get('inline') and partial[1]=='2': content=inline_png
                            if data.get('oversized'): content=b'x'*(int(partial[3])+1)
                            elif not data.get('wrong_origin'): content=content[int(partial[2]):int(partial[2])+int(partial[3])]
                            origin=1 if data.get('wrong_origin') else int(partial[2])
                            send(f'* {seq} FETCH (UID {uid} BODY[{partial[1]}]<{origin}> {{{len(content)}}}\r\n'.encode()+content+b')\r\n')
                        elif 'BODYSTRUCTURE' in upper:
                            threading=data.get('threads',{}).get(str(uid),{})
                            reply='"<'+threading['reply']+'>"' if threading.get('reply') else 'NIL'
                            envelope=(f'ENVELOPE ("Tue, 03 Nov 2026 10:00:00 +0000" "Fixture subject {uid}" (("Synthetic Sender" NIL "sender" "example.invalid")) NIL NIL ((NIL NIL "reader" "example.invalid")) NIL NIL {reply} "<{uid}@example.invalid>") ')
                            plain=f'("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" {len(body(uid))} 1 NIL NIL NIL NIL)'
                            html=f'("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "8BIT" {len(body(uid,True,data.get("inline"),data.get("large_html")))} 1 NIL NIL NIL NIL)'
                            size=data.get('attachment_size',len(base64.b64encode(b'x'*data.get('attachment_bytes',32))))
                            attachment=f'("APPLICATION" "PDF" ("NAME" "fixture.pdf") NIL NIL "BASE64" {size} NIL ("ATTACHMENT" ("FILENAME" "fixture.pdf")) NIL NIL)' 
                            structure=html if data.get('html_only') else '('+plain+(html if data.get('html') else attachment)+' "'+('ALTERNATIVE' if data.get('html') else 'MIXED')+'" ("BOUNDARY" "fixture") NIL NIL NIL)'
                            if data.get('inline'):
                                image=f'("IMAGE" "PNG" ("NAME" "logo.png") "<logo@mail>" NIL "BASE64" {len(inline_png)} NIL ("INLINE" ("FILENAME" "logo.png")) NIL NIL)'
                                unused=f'("IMAGE" "PNG" NIL "<unused@mail>" NIL "BASE64" {len(inline_png)} NIL NIL NIL NIL)'
                                structure='('+html+image+unused+' "RELATED" ("BOUNDARY" "fixture") NIL NIL NIL)'
                            prefix=f'FLAGS ({flags(uid)}) INTERNALDATE "03-Nov-2026 10:00:00 +0000" RFC822.SIZE 400 {envelope}' if 'ENVELOPE' in upper else ''
                            response=f'* {seq} FETCH (UID {uid} {prefix}BODYSTRUCTURE {structure}'
                            if 'HEADER.FIELDS' in upper:
                                headers=('References: '+' '.join('<'+x+'>' for x in threading.get('refs',[]))+'\r\n\r\n').encode()
                                send((response+f' BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO)] {{{len(headers)}}}\r\n').encode()+headers+b')\r\n')
                            else: send(response+')\r\n')
                        elif 'BODY[' in upper or 'RFC822.TEXT' in upper:
                            record('FORBIDDEN_BODY_READ'); send(tag+' BAD PEEK required\r\n'); break
                        else: send(f'* {seq} FETCH (UID {uid} FLAGS ({flags(uid)}))\r\n')
                else:
                    record('FORBIDDEN_COMMAND'); send(tag+' BAD unsupported by fixture\r\n'); continue
                send(tag+' OK completed\r\n')
    except (OSError,ssl.SSLError,ValueError): return
while True:
    raw,_=listener.accept(); threading.Thread(target=serve,args=(raw,),daemon=True).start()
