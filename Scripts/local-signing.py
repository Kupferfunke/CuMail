#!/usr/bin/env python3
"""Stable, private local development identity. Never exports an existing private key.

Only the public certificate fingerprint is persisted on disk. The non-extractable
private key lives in the user's default Keychain, trusted by /usr/bin/codesign.
This identity is for local builds; distribution still requires Developer ID.
"""
import os
from pathlib import Path
import secrets
import subprocess
import tempfile


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


root = Path.home() / 'Library/Application Support/MikeMailHubDevelopment'
root.mkdir(mode=0o700, parents=True, exist_ok=True)
pin = root / 'signing-identity.txt'
keychain = run(['/usr/bin/security', 'default-keychain', '-d', 'user']).decode().strip().strip('"')
if pin.exists():
    fingerprint = pin.read_text().strip()
    if len(fingerprint) != 40 or any(c not in '0123456789ABCDEF' for c in fingerprint):
        raise SystemExit('Invalid local signing identity pin; refusing to rotate the identity.')
    identities = run(['/usr/bin/security', 'find-identity', '-p', 'codesigning', keychain]).decode()
    if fingerprint not in identities:
        raise SystemExit('The pinned signing identity is missing from Keychain. Restore it before rebuilding; it will not be replaced automatically.')
else:
    existing = subprocess.run(['/usr/bin/security', 'find-certificate', '-c', 'Mike Mail Hub Local Development', '-Z', keychain], capture_output=True)
    if existing.returncode == 0:
        matches = [line.split(': ', 1)[1] for line in existing.stdout.decode().splitlines() if line.startswith('SHA-1 hash: ')]
        if len(matches) != 1:
            raise SystemExit('Ambiguous local signing identity; no certificate was changed.')
        fingerprint = matches[0]
    else:
        with tempfile.TemporaryDirectory(prefix='mike-mail-signing-') as temporary:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            configuration = directory / 'certificate.cnf'
            configuration.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Mike Mail Hub Local Development\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
            key, certificate, archive = (directory / name for name in ('key.pem', 'certificate.pem', 'identity.p12'))
            run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes', '-keyout', str(key), '-out', str(certificate), '-days', '3650', '-config', str(configuration)])
            os.chmod(key, 0o600)
            password = secrets.token_urlsafe(32)
            run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(certificate), '-out', str(archive), '-passout', 'stdin'], input=(password + '\n').encode())
            os.chmod(archive, 0o600)
            # Narrow executable ACL, non-extractable key; no trust-store changes.
            run(['/usr/bin/security', 'import', str(archive), '-k', keychain, '-P', password, '-x', '-T', '/usr/bin/codesign'])
            fingerprint = run(['/usr/bin/openssl', 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1']).decode().strip().split('=')[1].replace(':', '').upper()
            password = ''
    pin.write_text(fingerprint + '\n')
    os.chmod(pin, 0o600)
print(fingerprint)
