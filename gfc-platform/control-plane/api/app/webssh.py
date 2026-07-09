"""WebSSH bridge: admin WebSocket -> local reverse SSH port (control-plane side)."""
from __future__ import annotations

import asyncio
import logging
import shutil
from pathlib import Path

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from .db import async_session_factory
from .models import ClientDevice
from .reverse_ssh import session_active, tunnel_ready
from .security import decode_access_token
from .settings import settings

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/admin/ws", tags=["webssh"])


async def _load_device(device_id: int) -> ClientDevice | None:
    async with async_session_factory() as session:
        return await session.get(ClientDevice, device_id)


def _build_ssh_command(device: ClientDevice) -> list[str] | None:
    """Build ssh argv for device shell via reverse tunnel port."""
    port = str(device.reverse_ssh_port)
    target = f"{settings.reverse_ssh_client_shell_user}@127.0.0.1"
    ssh_opts = [
        "ssh",
        "-tt",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "NumberOfPasswordPrompts=0",
        "-p",
        port,
    ]
    identity = (settings.reverse_ssh_client_shell_identity_path or "").strip()
    if identity and Path(identity).is_file():
        ssh_opts.extend(["-i", identity, target])
        return ssh_opts

    password = (settings.reverse_ssh_client_shell_password or "").strip()
    if password:
        if not shutil.which("sshpass"):
            logger.error("sshpass not installed in API image")
            return None
        return ["sshpass", "-p", password, *ssh_opts, target]

    return None


def _missing_auth_message() -> str:
    return (
        "[webssh] 未配置设备 Shell 登录凭据。\n"
        "在控制平台设置 GFC_REVERSE_SSH_CLIENT_SHELL_PASSWORD（ImmortalWrt root 密码），\n"
        "或配置 GFC_REVERSE_SSH_CLIENT_SHELL_IDENTITY_PATH 指向 API 上的私钥，"
        "并把对应公钥写入设备 /etc/dropbear/authorized_keys。\n"
    )


@router.websocket("/ssh/{device_id}")
async def webssh_device(
    websocket: WebSocket,
    device_id: int,
    token: str | None = None,
) -> None:
    auth = websocket.headers.get("authorization") or ""
    bearer = ""
    if auth.lower().startswith("bearer "):
        bearer = auth.split(" ", 1)[1].strip()
    elif token:
        bearer = token.strip()
    if not bearer or not decode_access_token(bearer):
        await websocket.close(code=4401)
        return

    device = await _load_device(device_id)
    if not device or not device.reverse_ssh_port:
        await websocket.close(code=4404)
        return
    if not session_active(device) or not tunnel_ready(device):
        await websocket.close(code=4409)
        return

    ssh_args = _build_ssh_command(device)
    await websocket.accept()
    if ssh_args is None:
        await websocket.send_text(_missing_auth_message())
        await websocket.close()
        return

    try:
        proc = await asyncio.create_subprocess_exec(
            *ssh_args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
    except FileNotFoundError as exc:
        await websocket.send_text(f"[webssh] missing ssh client: {exc}\n")
        await websocket.close()
        return

    async def read_stdout() -> None:
        assert proc.stdout is not None
        while True:
            chunk = await proc.stdout.read(4096)
            if not chunk:
                break
            await websocket.send_bytes(chunk)

    async def read_ws() -> None:
        assert proc.stdin is not None
        while True:
            msg = await websocket.receive()
            if msg.get("type") == "websocket.disconnect":
                break
            data = msg.get("bytes") or msg.get("text", "").encode()
            if data:
                proc.stdin.write(data)
                await proc.stdin.drain()

    try:
        await asyncio.gather(read_stdout(), read_ws())
    except WebSocketDisconnect:
        pass
    finally:
        if proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=3)
            except asyncio.TimeoutError:
                proc.kill()
        await websocket.close()
