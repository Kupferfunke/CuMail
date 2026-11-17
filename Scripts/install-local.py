#!/usr/bin/env python3
"""Install the already verified local CuMail build without touching user data.

Quit CuMail first. This installs the existing stable local signature; it does not
claim Developer ID notarization or change the frozen Keychain helper.
"""
from pathlib import Path
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

project = Path(__file__).resolve().parent.parent
source = project / "build/CuMail.app"
destination = Path("/Applications/CuMail.app")
if subprocess.run(["/usr/bin/pgrep", "-x", "MikeMailHub"], capture_output=True).returncode == 0:
    raise SystemExit("Quit CuMail before installing; existing drafts must be flushed by the app.")
if not source.is_dir() or source.is_symlink() or destination.is_symlink():
    raise SystemExit("Unexpected app path; nothing installed.")
with (source / "Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
if info.get("CFBundleIdentifier") != "ch.kupferfunke.MikeMailHub":
    raise SystemExit("Unexpected bundle identity.")
helper = Path("Contents/XPCServices/MikeMailKeychain.xpc/Contents/MacOS/MikeMailKeychain")
expected = "8cf70b1ec1d9cf4ec816392d82604072e3a58be9b4097f362ae8e92543c01330"
if hashlib.sha256((source / helper).read_bytes()).hexdigest() != expected:
    raise SystemExit("Keychain helper changed; refusing the update.")
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
stage = Path(tempfile.mkdtemp(prefix=".CuMail-install-", dir="/Applications"))
previous = stage / "Previous.app"
try:
    staged = stage / "CuMail.app"
    subprocess.run(["/usr/bin/ditto", str(source), str(staged)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged)], check=True)
    if destination.exists():
        if not destination.is_dir():
            raise RuntimeError("Destination is not an app directory.")
        destination.rename(previous)
    try:
        staged.rename(destination)
    except BaseException:
        if previous.exists():
            previous.rename(destination)
        raise
    if previous.exists():
        archive = project / "build/ReplacedApps"
        archive.mkdir(exist_ok=True)
        previous.rename(archive / ("CuMail-" + str(uuid.uuid4()) + ".app.disabled"))
finally:
    # Never remove a previous app if an unexpected failure left it in staging.
    if not previous.exists():
        shutil.rmtree(stage)
subprocess.run([sys.executable, str(project / "Scripts/register-installed.py")], check=True)
print("Installed CuMail", info["CFBundleShortVersionString"], "at", destination)
