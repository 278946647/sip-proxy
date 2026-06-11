from __future__ import annotations

import secrets
import subprocess
from pathlib import Path
from typing import Any


class PkiError(RuntimeError):
    pass


def _run(cmd: list[str], cwd: Path | None = None) -> None:
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        raise PkiError((r.stderr or r.stdout or "openssl failed").strip())


def ensure_ca(pki_dir: Path) -> tuple[Path, Path]:
    """Create or reuse platform CA (ca.crt / ca.key)."""
    pki_dir.mkdir(parents=True, exist_ok=True)
    ca_crt = pki_dir / "ca.crt"
    ca_key = pki_dir / "ca.key"
    if ca_crt.is_file() and ca_key.is_file():
        return ca_crt, ca_key

    _run(["openssl", "genrsa", "-out", str(ca_key), "4096"], cwd=pki_dir)
    _run(
        [
            "openssl",
            "req",
            "-new",
            "-x509",
            "-days",
            "3650",
            "-key",
            str(ca_key),
            "-out",
            str(ca_crt),
            "-subj",
            "/CN=GFC Backbone CA",
        ],
        cwd=pki_dir,
    )
    ca_key.chmod(0o600)
    return ca_crt, ca_key


def issue_client_cert(pki_dir: Path, common_name: str) -> dict[str, str]:
    """Issue a client certificate signed by the platform CA."""
    if not common_name.strip():
        raise PkiError("common_name required")

    ca_crt, ca_key = ensure_ca(pki_dir)
    work = pki_dir / "clients" / common_name.replace("/", "_")
    work.mkdir(parents=True, exist_ok=True)

    client_key = work / "client.key"
    client_csr = work / "client.csr"
    client_crt = work / "client.crt"

    _run(["openssl", "genrsa", "-out", str(client_key), "2048"], cwd=work)
    _run(
        [
            "openssl",
            "req",
            "-new",
            "-key",
            str(client_key),
            "-out",
            str(client_csr),
            "-subj",
            f"/CN={common_name}",
        ],
        cwd=work,
    )
    _run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(client_csr),
            "-CA",
            str(ca_crt),
            "-CAkey",
            str(ca_key),
            "-CAcreateserial",
            "-out",
            str(client_crt),
            "-days",
            "825",
        ],
        cwd=work,
    )
    client_key.chmod(0o600)

    return {
        "ca": ca_crt.read_text(encoding="utf-8"),
        "cert": client_crt.read_text(encoding="utf-8"),
        "key": client_key.read_text(encoding="utf-8"),
        "common_name": common_name,
    }


def generate_static_key() -> str:
    """Generate OpenVPN static key (2048-bit pre-shared secret) without openvpn binary."""
    raw = secrets.token_bytes(256)
    hex_str = raw.hex()
    lines = [hex_str[i : i + 16] for i in range(0, len(hex_str), 16)]
    body = "\n".join(lines)
    return (
        "#\n"
        "# 2048 bit OpenVPN static key\n"
        "#\n"
        "-----BEGIN OpenVPN Static key V1-----\n"
        f"{body}\n"
        "-----END OpenVPN Static key V1-----\n"
    )


def pki_status(pki_dir: Path) -> dict[str, Any]:
    ca_crt = pki_dir / "ca.crt"
    return {
        "ca_ready": ca_crt.is_file(),
        "pki_dir": str(pki_dir),
    }
