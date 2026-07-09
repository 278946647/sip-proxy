"""Control-plane WebSSH keypair — auto login to client shell via reverse tunnel."""
from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from .settings import settings

logger = logging.getLogger(__name__)

_KEY_COMMENT = "gfc-webssh@control-plane"


def identity_path() -> Path:
    return Path(settings.pki_dir) / "webssh_id"


def public_key_path() -> Path:
    return identity_path().with_name(identity_path().name + ".pub")


def ensure_webssh_keypair() -> Path:
    """Create ed25519 keypair under PKI dir if missing (idempotent)."""
    identity = identity_path()
    pub = public_key_path()
    if identity.is_file() and pub.is_file():
        return identity
    identity.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ssh-keygen",
        "-t",
        "ed25519",
        "-f",
        str(identity),
        "-N",
        "",
        "-C",
        _KEY_COMMENT,
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError("ssh-keygen not installed in API image") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError((exc.stderr or exc.stdout or "ssh-keygen failed").strip()) from exc
    identity.chmod(0o600)
    pub.chmod(0o644)
    logger.info("generated WebSSH keypair at %s", identity)
    return identity


def webssh_public_key_line() -> str | None:
    """Return the single-line public key for client dropbear authorized_keys."""
    try:
        ensure_webssh_keypair()
    except RuntimeError as exc:
        logger.warning("webssh keypair unavailable: %s", exc)
        return None
    pub = public_key_path()
    if not pub.is_file():
        return None
    line = pub.read_text(encoding="utf-8").strip()
    return line or None


def resolved_shell_identity_path() -> str:
    """Private key path for WebSSH ssh -i (explicit setting or auto PKI)."""
    explicit = (settings.reverse_ssh_client_shell_identity_path or "").strip()
    if explicit:
        return explicit
    identity = identity_path()
    if identity.is_file():
        return str(identity)
    try:
        return str(ensure_webssh_keypair())
    except RuntimeError:
        return ""
