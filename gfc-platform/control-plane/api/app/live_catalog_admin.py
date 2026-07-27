"""Admin API for live catalog operations (P2)."""
from __future__ import annotations

import json

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .auth_deps import get_current_user, require_action
from .db import get_session
from .live_catalog import (
    capture_candidate_to_dict,
    find_endpoint_duplicate,
    list_live_platforms,
    utc_now,
)
from .models import LiveCaptureCandidate, LiveEndpoint, LivePlatform, PlatformUser
from .schemas import (
    LiveCaptureCandidateCreateIn,
    LiveCaptureCandidateOut,
    LiveCaptureReviewIn,
    LiveEndpointCreateIn,
    LiveEndpointOut,
    LiveEndpointUpdateIn,
    LivePlatformOut,
    LivePlatformPatchIn,
)

router = APIRouter(tags=["live-catalog"])


def _endpoint_out(ep: LiveEndpoint) -> LiveEndpointOut:
    return LiveEndpointOut(
        id=ep.id,
        platform_id=ep.platform_id,
        role=ep.role,
        match_type=ep.match_type,
        value=ep.value,
        confidence=ep.confidence,
        source=ep.source,
        status=ep.status,
        region=ep.region,
        last_verified_at=ep.last_verified_at,
        created_at=ep.created_at,
    )


def _candidate_out(row: LiveCaptureCandidate) -> LiveCaptureCandidateOut:
    data = capture_candidate_to_dict(row)
    return LiveCaptureCandidateOut(
        id=data["id"],
        platform_id=data["platformId"],
        role=data["role"],
        match_type=data["matchType"],
        value=data["value"],
        confidence=data["confidence"],
        source=data["source"],
        status=data["status"],
        notes=data.get("notes"),
        line_id=data.get("lineId"),
        evidence=data.get("evidence") or {},
        reviewed_by=data.get("reviewedBy"),
        reviewed_at=row.reviewed_at,
        endpoint_id=data.get("endpointId"),
        created_at=row.created_at,
    )


@router.get("/live-platforms", response_model=list[LivePlatformOut])
async def list_live_platform_catalog(
    session: AsyncSession = Depends(get_session),
) -> list[LivePlatformOut]:
    rows = await list_live_platforms(session)
    pending_counts: dict[str, int] = {}
    pending_rows = (
        await session.execute(
            select(LiveCaptureCandidate.platform_id, func.count())
            .where(LiveCaptureCandidate.status == "pending")
            .group_by(LiveCaptureCandidate.platform_id)
        )
    ).all()
    for platform_id, count in pending_rows:
        pending_counts[str(platform_id)] = int(count)

    draft_counts: dict[str, int] = {}
    draft_rows = (
        await session.execute(
            select(LiveEndpoint.platform_id, func.count())
            .where(LiveEndpoint.status == "draft")
            .group_by(LiveEndpoint.platform_id)
        )
    ).all()
    for platform_id, count in draft_rows:
        draft_counts[str(platform_id)] = int(count)

    return [
        LivePlatformOut(
            id=r["id"],
            display_name=r["displayName"],
            markets=r.get("markets") or [],
            live_strength=r.get("liveStrength") or "strong",
            is_enabled=bool(r.get("isEnabled", True)),
            endpoint_count=int(r.get("endpointCount") or 0),
            active_endpoint_count=int(r.get("activeEndpointCount") or 0),
            draft_endpoint_count=int(draft_counts.get(r["id"], 0)),
            pending_capture_count=int(pending_counts.get(r["id"], 0)),
        )
        for r in rows
    ]


@router.patch(
    "/live-platforms/{platform_id}",
    response_model=LivePlatformOut,
    dependencies=[Depends(require_action("write_safe"))],
)
async def patch_live_platform(
    platform_id: str,
    body: LivePlatformPatchIn,
    session: AsyncSession = Depends(get_session),
) -> LivePlatformOut:
    row = await session.get(LivePlatform, platform_id)
    if not row:
        raise HTTPException(404, "platform not found")
    data = body.model_dump(exclude_unset=True)
    for key, value in data.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    items = await list_live_platform_catalog(session)
    for item in items:
        if item.id == platform_id:
            return item
    raise HTTPException(500, "platform refresh failed")


@router.get("/live-endpoints", response_model=list[LiveEndpointOut])
async def list_live_endpoints(
    platform_id: str | None = Query(default=None),
    status: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session),
) -> list[LiveEndpointOut]:
    stmt = select(LiveEndpoint).order_by(LiveEndpoint.platform_id, LiveEndpoint.id)
    if platform_id:
        stmt = stmt.where(LiveEndpoint.platform_id == platform_id)
    if status:
        stmt = stmt.where(LiveEndpoint.status == status)
    rows = (await session.execute(stmt)).scalars().all()
    return [_endpoint_out(r) for r in rows]


@router.post(
    "/live-endpoints",
    response_model=LiveEndpointOut,
    dependencies=[Depends(require_action("write_safe"))],
)
async def create_live_endpoint(
    body: LiveEndpointCreateIn,
    session: AsyncSession = Depends(get_session),
) -> LiveEndpointOut:
    platform = await session.get(LivePlatform, body.platform_id)
    if not platform:
        raise HTTPException(400, "platform not found")
    dup = await find_endpoint_duplicate(
        session, body.platform_id, body.match_type, body.value.strip()
    )
    if dup:
        raise HTTPException(409, "endpoint already exists")
    now = utc_now()
    ep = LiveEndpoint(
        platform_id=body.platform_id,
        role=body.role,
        match_type=body.match_type,
        value=body.value.strip(),
        confidence=body.confidence,
        source=body.source,
        status=body.status,
        region=body.region,
        last_verified_at=now if body.status == "active" else None,
        created_at=now,
    )
    session.add(ep)
    await session.commit()
    await session.refresh(ep)
    return _endpoint_out(ep)


@router.patch(
    "/live-endpoints/{endpoint_id}",
    response_model=LiveEndpointOut,
    dependencies=[Depends(require_action("write_safe"))],
)
async def update_live_endpoint(
    endpoint_id: int,
    body: LiveEndpointUpdateIn,
    session: AsyncSession = Depends(get_session),
) -> LiveEndpointOut:
    ep = await session.get(LiveEndpoint, endpoint_id)
    if not ep:
        raise HTTPException(404, "endpoint not found")
    data = body.model_dump(exclude_unset=True)
    if "value" in data and data["value"] is not None:
        data["value"] = data["value"].strip()
    match_type = data.get("match_type", ep.match_type)
    value = data.get("value", ep.value)
    dup = await find_endpoint_duplicate(
        session, ep.platform_id, match_type, value, exclude_id=ep.id
    )
    if dup:
        raise HTTPException(409, "endpoint already exists")
    for key, val in data.items():
        setattr(ep, key, val)
    if data.get("status") == "active":
        ep.last_verified_at = utc_now()
    session.add(ep)
    await session.commit()
    await session.refresh(ep)
    return _endpoint_out(ep)


@router.delete(
    "/live-endpoints/{endpoint_id}",
    dependencies=[Depends(require_action("write_safe"))],
)
async def delete_live_endpoint(
    endpoint_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict[str, bool]:
    ep = await session.get(LiveEndpoint, endpoint_id)
    if not ep:
        raise HTTPException(404, "endpoint not found")
    await session.delete(ep)
    await session.commit()
    return {"ok": True}


@router.get("/live-capture-candidates", response_model=list[LiveCaptureCandidateOut])
async def list_capture_candidates(
    status: str = Query(default="pending"),
    platform_id: str | None = Query(default=None),
    session: AsyncSession = Depends(get_session),
) -> list[LiveCaptureCandidateOut]:
    stmt = select(LiveCaptureCandidate).order_by(LiveCaptureCandidate.id.desc())
    if status:
        stmt = stmt.where(LiveCaptureCandidate.status == status)
    if platform_id:
        stmt = stmt.where(LiveCaptureCandidate.platform_id == platform_id)
    rows = (await session.execute(stmt)).scalars().all()
    return [_candidate_out(r) for r in rows]


@router.post(
    "/live-capture-candidates",
    response_model=LiveCaptureCandidateOut,
    dependencies=[Depends(require_action("write_safe"))],
)
async def create_capture_candidate(
    body: LiveCaptureCandidateCreateIn,
    session: AsyncSession = Depends(get_session),
) -> LiveCaptureCandidateOut:
    platform = await session.get(LivePlatform, body.platform_id)
    if not platform:
        raise HTTPException(400, "platform not found")
    value = body.value.strip()
    pending = (
        await session.execute(
            select(LiveCaptureCandidate)
            .where(LiveCaptureCandidate.platform_id == body.platform_id)
            .where(LiveCaptureCandidate.match_type == body.match_type)
            .where(LiveCaptureCandidate.value == value)
            .where(LiveCaptureCandidate.status == "pending")
        )
    ).scalars().first()
    if pending:
        raise HTTPException(409, "pending candidate already exists")
    row = LiveCaptureCandidate(
        platform_id=body.platform_id,
        role=body.role,
        match_type=body.match_type,
        value=value,
        confidence=body.confidence,
        source="capture",
        status="pending",
        notes=body.notes,
        line_id=body.line_id,
        evidence_json=json.dumps(body.evidence or {}, ensure_ascii=False),
        created_at=utc_now(),
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return _candidate_out(row)


@router.post(
    "/live-capture-candidates/{candidate_id}/approve",
    response_model=LiveCaptureCandidateOut,
    dependencies=[Depends(require_action("write_safe"))],
)
async def approve_capture_candidate(
    candidate_id: int,
    body: LiveCaptureReviewIn,
    session: AsyncSession = Depends(get_session),
    operator: PlatformUser = Depends(get_current_user),
) -> LiveCaptureCandidateOut:
    row = await session.get(LiveCaptureCandidate, candidate_id)
    if not row:
        raise HTTPException(404, "candidate not found")
    if row.status != "pending":
        raise HTTPException(400, f"candidate status is {row.status}")
    now = utc_now()
    endpoint_id = row.endpoint_id
    if body.activate:
        dup = await find_endpoint_duplicate(
            session, row.platform_id, row.match_type, row.value
        )
        if dup:
            endpoint_id = dup.id
            if dup.status != "active":
                dup.status = "active"
                dup.last_verified_at = now
                dup.source = row.source
                dup.confidence = row.confidence
                session.add(dup)
        else:
            ep = LiveEndpoint(
                platform_id=row.platform_id,
                role=row.role,
                match_type=row.match_type,
                value=row.value,
                confidence=row.confidence,
                source=row.source,
                status="active",
                last_verified_at=now,
                created_at=now,
            )
            session.add(ep)
            await session.flush()
            endpoint_id = ep.id
    row.status = "approved"
    row.reviewed_by = operator.username
    row.reviewed_at = now
    row.endpoint_id = endpoint_id
    if body.notes:
        row.notes = body.notes
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return _candidate_out(row)


@router.post(
    "/live-capture-candidates/{candidate_id}/reject",
    response_model=LiveCaptureCandidateOut,
    dependencies=[Depends(require_action("write_safe"))],
)
async def reject_capture_candidate(
    candidate_id: int,
    body: LiveCaptureReviewIn,
    session: AsyncSession = Depends(get_session),
    operator: PlatformUser = Depends(get_current_user),
) -> LiveCaptureCandidateOut:
    row = await session.get(LiveCaptureCandidate, candidate_id)
    if not row:
        raise HTTPException(404, "candidate not found")
    if row.status != "pending":
        raise HTTPException(400, f"candidate status is {row.status}")
    row.status = "rejected"
    row.reviewed_by = operator.username
    row.reviewed_at = utc_now()
    if body.notes:
        row.notes = body.notes
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return _candidate_out(row)
