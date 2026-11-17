#!/usr/bin/env python3
"""Put an explicitly supplied public OAuth registration in a local build only."""
import argparse
import os
from pathlib import Path
import plistlib
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client-id', default=os.environ.get('CUMAIL_GOOGLE_CLIENT_ID', ''))
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    client_id = args.client_id.strip()
    if client_id and not re.fullmatch(r'[0-9]+-[A-Za-z0-9-]+\.apps\.googleusercontent\.com', client_id):
        parser.error('Expected a public native Google client ID, not a secret or password.')
    root = Path(__file__).resolve().parents[1]
    template = root / 'Config' / 'Info.plist'
    output = args.output.resolve()
    if output == template.resolve():
        parser.error('Refusing to overwrite the shared Info.plist; use a local output file.')
    data = plistlib.loads(template.read_bytes())
    types = [item for item in data.get('CFBundleURLTypes', []) if item.get('CFBundleURLName') != 'Google OAuth']
    data.pop('CuMailGoogleClientID', None)
    if client_id:
        data['CuMailGoogleClientID'] = client_id
        types.insert(0, {'CFBundleURLName': 'Google OAuth',
                         'CFBundleURLSchemes': ['.'.join(reversed(client_id.split('.')))]})
    data['CFBundleURLTypes'] = types
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(data, sort_keys=False))


if __name__ == '__main__':
    main()
