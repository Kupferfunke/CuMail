#!/usr/bin/env python3
"""Exercise the signed external byte adapter against a disposable private peer.

No real app container, account, credential, or network is accessed.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
bridge = root / "build/CuMail.app/Contents/Helpers/MikeMailBridge"
with tempfile.TemporaryDirectory(prefix="mmh-bridge-", dir="/tmp") as directory:
    os.chmod(directory, 0o700)
    endpoint = str(Path(directory) / "mail.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(endpoint)
        os.chmod(endpoint, 0o600)
        listener.listen(1)
        listener.settimeout(5)
        child = subprocess.Popen(
            [str(bridge), "--socket", endpoint],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin"},
        )
        try:
            with listener.accept()[0] as peer:
                peer.settimeout(5)
                child.stdin.write(b'{"synthetic":"ping"}\n')
                child.stdin.flush()
                assert peer.recv(512) == b'{"synthetic":"ping"}\n'
                peer.sendall(b'{"synthetic":"pong"}\n')
            output, errors = child.communicate(timeout=5)
            assert output == b'{"synthetic":"pong"}\n'
            assert child.returncode == 0 and not errors
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

        os.chmod(directory, 0o755)
        denied = subprocess.run(
            [str(bridge), "--socket", endpoint], input=b"",
            capture_output=True, timeout=5, env={"PATH": "/usr/bin:/bin"},
        )
        assert denied.returncode == 1 and not denied.stdout

print(json.dumps({"signedExternalBridgeRoundTrip": True,
                  "sharedDirectoryRejected": True, "realDataAccessed": False}))
