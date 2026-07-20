"""Runtime OTA artifact storage and admin/client download APIs."""
from __future__ import annotations

import hashlib
import json
import logging
import re
import uuid
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .auth_deps import get_current_user, require_action
from .db import get_session
from .models import ClientDevice, PlatformUser, RuntimeArtifact
from .schemas import (
    ClientDeviceDetailOut,
    ClientDeviceUpgradeIn,
    RuntimeArtifactMetaOut,
    RuntimeArtifactOut,
    RuntimeArtifactUpdateIn,
)
from .server_url_util import public_server_urls
from .settings import settings
from .timeutil import utc_now

logger = logging.getLogger(__name__)

admin_router = APIRouter(prefix="/admin/artifacts", tags=["artifacts"])
# Client artifact routes are mounted under /clients in clients.py helpers.

# Keep in sync with upload_artifact size check and web-ui nginx client_max_body_size.
MAX_ARTIFACT_BYTES = 512 * 1024 * 1024


def artifacts_root() -> Path:
    root = Path(settings.artifacts_dir)
    root.mkdir(parents=True, exist_ok=True)
    return root


def _artifact_to_out(row: RuntimeArtifact) -> RuntimeArtifactOut:
    return RuntimeArtifactOut(
        id=row.id,
        version=row.version,
        arch=row.arch,
        filename=row.filename,
        sha256=row.sha256,
        size_bytes=row.size_bytes or 0,
        notes=row.notes,
        is_enabled=bool(row.is_enabled),
        created_by=row.created_by or "admin",
        created_at=row.created_at,
    )


def _guess_arch(filename: str, explicit: str | None) -> str:
    if explicit:
        a = explicit.strip().lower()
        if a in ("amd64", "x86_64", "x64"):
            return "amd64"
        if a in ("arm64", "aarch64"):
            return "arm64"
        raise HTTPException(400, f"unsupported arch: {explicit}")
    name = filename.lower()
    if "arm64" in name or "aarch64" in name:
        return "arm64"
    if "amd64" in name or "x86_64" in name:
        return "amd64"
    raise HTTPException(400, "cannot detect arch from filename; pass arch=amd64|arm64")


def _sanitize_version(version: str) -> str:
    v = version.strip()
    if not v or len(v) > 64:
        raise HTTPException(400, "invalid version")
    if not re.match(r"^[\w.\-+]+$", v):
        raise HTTPException(400, "version contains invalid characters")
    return v


async def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


@admin_router.get("", response_model=list[RuntimeArtifactOut], dependencies=[Depends(require_action("read"))])
async def list_artifacts(
    session: AsyncSession = Depends(get_session),
    arch: str | None = Query(None),
    enabled_only: bool = Query(False),
) -> list[RuntimeArtifactOut]:
    stmt = select(RuntimeArtifact).order_by(RuntimeArtifact.id.desc())
    if arch:
        stmt = stmt.where(RuntimeArtifact.arch == arch.strip().lower())
    if enabled_only:
        stmt = stmt.where(RuntimeArtifact.is_enabled.is_(True))
    rows = (await session.execute(stmt)).scalars().all()
    return [_artifact_to_out(r) for r in rows]


@admin_router.get("/meta", response_model=RuntimeArtifactMetaOut, dependencies=[Depends(require_action("read"))])
async def artifacts_meta() -> RuntimeArtifactMetaOut:
    """Expose configured storage directory for admin UI (not per-upload editable)."""
    return RuntimeArtifactMetaOut(
        storage_dir=str(artifacts_root()),
        max_size_bytes=MAX_ARTIFACT_BYTES,
    )


@admin_router.post("", response_model=RuntimeArtifactOut, dependencies=[Depends(require_action("write_safe"))])
async def upload_artifact(
    file: UploadFile = File(...),
    version: str = Form(...),
    arch: str | None = Form(None),
    notes: str | None = Form(None),
    session: AsyncSession = Depends(get_session),
    operator: PlatformUser = Depends(get_current_user),
) -> RuntimeArtifactOut:
    filename = (file.filename or "package.tar.gz").strip()
    if not filename.endswith((".tar.gz", ".tgz")):
        raise HTTPException(400, "only .tar.gz / .tgz runtime packages are accepted")
    ver = _sanitize_version(version)
    arch_norm = _guess_arch(filename, arch)

    root = artifacts_root()
    storage_name = f"{ver}_{arch_norm}_{uuid.uuid4().hex[:10]}.tar.gz"
    dest = root / storage_name
    size = 0
    try:
        with dest.open("wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_ARTIFACT_BYTES:
                    raise HTTPException(400, "artifact too large (max 512MB)")
                out.write(chunk)
        digest = await sha256_file(dest)
    except HTTPException:
        dest.unlink(missing_ok=True)
        raise
    except Exception as exc:
        dest.unlink(missing_ok=True)
        raise HTTPException(500, f"failed to store artifact: {exc}") from exc

    row = RuntimeArtifact(
        version=ver,
        arch=arch_norm,
        filename=filename,
        sha256=digest,
        size_bytes=size,
        storage_name=storage_name,
        notes=(notes or "").strip() or None,
        is_enabled=True,
        created_by=operator.username,
        created_at=utc_now(),
    )
    session.add(row)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        dest.unlink(missing_ok=True)
        raise HTTPException(409, f"artifact version+arch already exists: {ver}/{arch_norm}") from exc
    await session.refresh(row)
    return _artifact_to_out(row)


@admin_router.patch("/{artifact_id}", response_model=RuntimeArtifactOut, dependencies=[Depends(require_action("write_safe"))])
async def update_artifact(
    artifact_id: int,
    body: RuntimeArtifactUpdateIn,
    session: AsyncSession = Depends(get_session),
) -> RuntimeArtifactOut:
    row = await session.get(RuntimeArtifact, artifact_id)
    if not row:
        raise HTTPException(404, "artifact not found")
    data = body.model_dump(exclude_unset=True)
    for k, v in data.items():
        setattr(row, k, v)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return _artifact_to_out(row)


@admin_router.delete("/{artifact_id}", dependencies=[Depends(require_action("delete"))])
async def delete_artifact(
    artifact_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict[str, bool]:
    row = await session.get(RuntimeArtifact, artifact_id)
    if not row:
        raise HTTPException(404, "artifact not found")
    path = artifacts_root() / row.storage_name
    await session.delete(row)
    await session.commit()
    path.unlink(missing_ok=True)
    return {"ok": True}


@admin_router.get("/{artifact_id}/download", dependencies=[Depends(require_action("read"))])
async def admin_download_artifact(
    artifact_id: int,
    session: AsyncSession = Depends(get_session),
) -> FileResponse:
    row = await session.get(RuntimeArtifact, artifact_id)
    if not row:
        raise HTTPException(404, "artifact not found")
    path = artifacts_root() / row.storage_name
    if not path.is_file():
        raise HTTPException(404, "artifact file missing on disk")
    return FileResponse(path, filename=row.filename, media_type="application/gzip")


def build_upgrade_command(artifact: RuntimeArtifact, request_id: str) -> dict[str, Any]:
    base = public_server_urls()[0].rstrip("/") if public_server_urls() else ""
    return {
        "action": "runtime_upgrade",
        "requestId": request_id,
        "artifactId": artifact.id,
        "version": artifact.version,
        "arch": artifact.arch,
        "sha256": artifact.sha256,
        "filename": artifact.filename,
        "downloadPath": f"/clients/artifacts/{artifact.id}/download",
        "downloadUrl": f"{base}/clients/artifacts/{artifact.id}/download" if base else "",
    }


async def queue_device_upgrade(
    session: AsyncSession,
    device: ClientDevice,
    artifact: RuntimeArtifact,
    operator: str,
) -> ClientDevice:
    if not artifact.is_enabled:
        raise HTTPException(400, "artifact is disabled")
    request_id = str(uuid.uuid4())
    cmd = build_upgrade_command(artifact, request_id)
    device.pending_device_command_json = json.dumps(cmd, ensure_ascii=False)
    device.last_upgrade_json = json.dumps(
        {
            "status": "queued",
            "version": artifact.version,
            "artifact_id": artifact.id,
            "request_id": request_id,
            "message": f"queued by {operator}",
            "at": utc_now().isoformat(),
        },
        ensure_ascii=False,
    )
    session.add(device)
    return device
