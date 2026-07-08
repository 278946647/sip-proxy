"""WebSSH bridge: admin WebSocket -> local reverse SSH port (control-plane side)."""
from __future__ import annotations

import asyncio
import logging

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

    await websocket.accept()
    ssh_args = [
        "ssh",
        "-tt",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-p",
        str(device.reverse_ssh_port),
        f"{settings.reverse_ssh_client_shell_user}@127.0.0.1",
    ]
    if settings.reverse_ssh_client_shell_password:
        ssh_args = [
            "sshpass",
            "-p",
            settings.reverse_ssh_client_shell_password,
            *ssh_args,
        ]
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
