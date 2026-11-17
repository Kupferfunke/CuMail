#!/usr/bin/env python3
"""Fetch one checksum-pinned official OpenAI transport; never starts it."""
from pathlib import Path
from urllib.request import urlopen
import hashlib
import os
import platform
import sys
import zipfile

VERSION = "0.0.19"
HASHES = {
    "arm64": "2243d024b77af8ee4b4ab7a1447949e5fc8d82bcd2d51b178927f2da9e47ecfd",
    "amd64": "dff97674c77cac59e6ab3d901e6cff50fb17a5784c01d8959d1f4adb3afdf4bf",
}
arch = (sys.argv[1] if len(sys.argv) > 1 else platform.machine())
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(arch, arch)
if arch not in HASHES:
    raise SystemExit("Unsupported tunnel-client architecture")
root = Path(__file__).resolve().parents[1]
destination = root / "build" / "tool-cache" / f"tunnel-client-{VERSION}-{arch}"
destination.mkdir(parents=True, exist_ok=True)
archive = destination / f"tunnel-client-v{VERSION}-darwin-{arch}.zip"
if not archive.exists():
    url = f"https://github.com/openai/tunnel-client/releases/download/v{VERSION}/{archive.name}"
    with urlopen(url, timeout=60) as response:
        data = response.read(128 * 1024 * 1024 + 1)
    if len(data) > 128 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != HASHES[arch]:
        raise SystemExit("Tunnel-client download checksum mismatch")
    temporary = archive.with_suffix(".download")
    temporary.write_bytes(data); os.replace(temporary, archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != HASHES[arch]:
    raise SystemExit("Cached tunnel-client checksum mismatch")
with zipfile.ZipFile(archive) as bundle:
    # We use the OpenAI HTTPS transport only, without the Cloudflare companion.
    for name in ("tunnel-client", "LICENSE", "NOTICE", f"tunnel-client-v{VERSION}-darwin-{arch}-licenses.txt"):
        (destination / name).write_bytes(bundle.read(name))
(destination / "tunnel-client").chmod(0o755)
print(destination)
