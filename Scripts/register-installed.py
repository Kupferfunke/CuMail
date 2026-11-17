#!/usr/bin/env python3
"""Prefer the installed CuMail for its existing URL schemes; keep build files intact."""
from pathlib import Path
import plistlib
import subprocess

project = Path(__file__).resolve().parent.parent
installed = Path('/Applications/CuMail.app')
register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
with (installed / 'Contents/Info.plist').open('rb') as file:
    if plistlib.load(file).get('CFBundleIdentifier') != 'ch.kupferfunke.MikeMailHub':
        raise SystemExit('Unexpected installed app identity.')
count = 0
for app in (project / 'build').rglob('*.app'):
    try:
        with (app / 'Contents/Info.plist').open('rb') as file:
            info = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException):
        continue
    if info.get('CFBundleIdentifier') == 'ch.kupferfunke.MikeMailHub':
        result = subprocess.run([register, '-u', str(app)], capture_output=True, text=True)
        # Launch Services reports kLSApplicationNotFoundErr for a bundle that
        # was already removed from its registry; that is the desired state.
        if result.returncode and '-10814' not in result.stdout + result.stderr:
            raise RuntimeError('Could not unregister historical bundle: ' + str(app))
        count += 1
subprocess.run([register, '-f', str(installed)], check=True)
print('Registered /Applications/CuMail.app;', count, 'historical build bundles unregistered or already absent.')
