from __future__ import annotations

import os
import subprocess
from pathlib import Path

TLS_DIR = Path(os.environ.get("GFC_WEB_TLS_DIR", "/etc/gfc-client/web-tls"))
CERT_FILE = TLS_DIR / "server.pem"
KEY_FILE = TLS_DIR / "server-key.pem"


def ensure_self_signed_cert(
    hostname: str = "192.168.68.1",
    *,
    days: int = 3650,
) -> tuple[Path, Path]:
    TLS_DIR.mkdir(parents=True, exist_ok=True)
    if CERT_FILE.is_file() and KEY_FILE.is_file():
        return CERT_FILE, KEY_FILE

    san = f"IP:{hostname},DNS:gfc-client.local,DNS:localhost"
    cmd = [
        "openssl",
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        str(KEY_FILE),
        "-out",
        str(CERT_FILE),
        "-days",
        str(days),
        "-subj",
        f"/CN={hostname}/O=GFC Client",
        "-addext",
        f"subjectAltName={san}",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        raise RuntimeError(f"openssl cert failed: {r.stderr or r.stdout}")
    os.chmod(KEY_FILE, 0o600)
    os.chmod(CERT_FILE, 0o644)
    return CERT_FILE, KEY_FILE
