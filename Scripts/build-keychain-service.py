#!/usr/bin/env python3
"""Build once, then verify and reuse an immutable private Keychain XPC service."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parent.parent
fingerprint = sys.argv[1]
if len(fingerprint) != 40 or any(c not in '0123456789ABCDEF' for c in fingerprint):
    raise SystemExit('Invalid signing identity')
sources = [project / 'Packages/MikeMailCore/Sources/MailSecurity/KeychainXPCProtocol.swift', project / 'Services/KeychainService/main.swift']
source_digest = hashlib.sha256(b''.join(p.read_bytes() for p in sources) + Path(__file__).read_bytes()).hexdigest()
cache = Path.home() / 'Library/Application Support/MikeMailHubDevelopment/KeychainService'
cache.mkdir(mode=0o700, parents=True, exist_ok=True)
bundle = cache / 'MikeMailKeychain.xpc'
manifest = cache / 'manifest.json'

def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file()}

if bundle.exists():
    record = json.loads(manifest.read_text())
    if record['certificate'] != fingerprint or record['source'] != source_digest or record['files'] != hashes(bundle):
        raise SystemExit('The pinned Keychain service changed. Review its explicit migration before replacing it.')
else:
    with tempfile.TemporaryDirectory(prefix='keychain-service-', dir=cache) as directory:
        staging = Path(directory) / bundle.name
        executable = staging / 'Contents/MacOS/MikeMailKeychain'
        executable.parent.mkdir(parents=True)
        info = {'CFBundleIdentifier':'ch.kupferfunke.MikeMailHub.KeychainService','CFBundleName':'Mike Mail Hub Schlüsselbund',
                'CFBundleExecutable':'MikeMailKeychain','CFBundlePackageType':'XPC!','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
                'MMHKeychainCertificateSHA1':fingerprint,'XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop','JoinExistingSession':True}}
        (staging/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        entitlements = Path(directory)/'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
        subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-target','arm64-apple-macos15.0',*map(str,sources),'-o',str(executable)],check=True)
        subprocess.run(['/usr/bin/codesign','--force','--sign',fingerprint,'--timestamp=none','--entitlements',str(entitlements),str(staging)],check=True)
        staging.rename(bundle)
    manifest.write_text(json.dumps({'certificate':fingerprint,'source':source_digest,'files':hashes(bundle)},indent=2)+'\n')
subprocess.run(['/usr/bin/codesign','--verify','--strict','-R',f'=identifier "ch.kupferfunke.MikeMailHub.KeychainService" and certificate leaf = H"{fingerprint}"',str(bundle)],check=True)
print(bundle)
