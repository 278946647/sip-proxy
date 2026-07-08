from __future__ import annotations

import datetime as dt

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class Node(Base):
    __tablename__ = "nodes"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_key: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(128))
    region: Mapped[str] = mapped_column(String(64))
    country: Mapped[str | None] = mapped_column(String(64), nullable=True)
    public_ip: Mapped[str | None] = mapped_column(String(64), nullable=True)

    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    last_seen_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )

    current_config_version: Mapped[str | None] = mapped_column(String(64), nullable=True)
    connect_mode: Mapped[str] = mapped_column(String(32), default="ethernet")
    vpn_config_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    last_metrics_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    agent_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    static_routes_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    reality_config_json: Mapped[str | None] = mapped_column(Text, nullable=True)

    traffic_monitor_iface: Mapped[str | None] = mapped_column(String(64), nullable=True)
    traffic_billing_start_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    traffic_billing_cycle_days: Mapped[int] = mapped_column(Integer, default=30)
    traffic_monthly_quota_gb: Mapped[int | None] = mapped_column(Integer, nullable=True)
    traffic_correction_bytes: Mapped[int] = mapped_column(Integer, default=0)
    traffic_pending_bytes_in: Mapped[int] = mapped_column(Integer, default=0)
    traffic_pending_bytes_out: Mapped[int] = mapped_column(Integer, default=0)
    traffic_last_sample_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    tokens: Mapped[list["NodeToken"]] = relationship(
        back_populates="node", cascade="all, delete-orphan"
    )


class NodeToken(Base):
    __tablename__ = "node_tokens"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_id: Mapped[int] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"))
    token_hash: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )
    expires_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revoked_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    node: Mapped["Node"] = relationship(back_populates="tokens")


class SocksProfile(Base):
    __tablename__ = "socks_profiles"
    __table_args__ = (UniqueConstraint("name", name="uq_socks_name"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(128))
    host: Mapped[str] = mapped_column(String(255))
    port: Mapped[int] = mapped_column(Integer)
    username: Mapped[str | None] = mapped_column(String(255), nullable=True)
    password: Mapped[str | None] = mapped_column(String(255), nullable=True)
    country: Mapped[str | None] = mapped_column(String(128), nullable=True)
    channel: Mapped[str | None] = mapped_column(String(128), nullable=True)
    remark: Mapped[str | None] = mapped_column(Text, nullable=True)
    is_healthy: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )


class Line(Base):
    __tablename__ = "lines"
    __table_args__ = (UniqueConstraint("tid", name="uq_line_tid"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    tid: Mapped[str] = mapped_column(String(64), index=True)
    name: Mapped[str] = mapped_column(String(128))
    source_cidrs: Mapped[str] = mapped_column(String(2048))

    node_id: Mapped[int] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"))
    socks_profile_id: Mapped[int | None] = mapped_column(
        ForeignKey("socks_profiles.id", ondelete="RESTRICT"), nullable=True
    )
    line_type: Mapped[str] = mapped_column(String(32), default="client")
    client_uuid: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    line_code_b32: Mapped[str | None] = mapped_column(Text, nullable=True)

    country: Mapped[str] = mapped_column(String(64), default="")
    bandwidth_mbps: Mapped[int] = mapped_column(Integer, default=5)
    channel: Mapped[str] = mapped_column(String(128), default="")
    remark: Mapped[str | None] = mapped_column(Text, nullable=True)
    socks_remark: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(32), default="active")
    is_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    flow_stats_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    created_by: Mapped[str] = mapped_column(String(64), default="admin")
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )

    node: Mapped["Node"] = relationship()
    socks_profile: Mapped["SocksProfile"] = relationship()
    client_device: Mapped["ClientDevice | None"] = relationship(
        back_populates="line", uselist=False
    )


class ClientDevice(Base):
    __tablename__ = "client_devices"
    __table_args__ = (UniqueConstraint("device_key", name="uq_client_device_key"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_key: Mapped[str] = mapped_column(String(64), index=True)
    name: Mapped[str] = mapped_column(String(128))
    lan_mac: Mapped[str | None] = mapped_column(String(32), nullable=True)
    device_id: Mapped[str | None] = mapped_column(String(32), nullable=True, index=True)
    line_id: Mapped[int | None] = mapped_column(
        ForeignKey("lines.id", ondelete="SET NULL"), nullable=True, unique=True
    )
    reverse_ssh_port: Mapped[int | None] = mapped_column(Integer, nullable=True)
    proxy_mode: Mapped[str] = mapped_column(String(32), default="gateway")
    agent_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    last_seen_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_metrics_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )

    line: Mapped["Line | None"] = relationship(back_populates="client_device")
    tokens: Mapped[list["ClientToken"]] = relationship(
        back_populates="device", cascade="all, delete-orphan"
    )


class ClientToken(Base):
    __tablename__ = "client_tokens"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_id: Mapped[int] = mapped_column(
        ForeignKey("client_devices.id", ondelete="CASCADE")
    )
    token_hash: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )
    expires_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revoked_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    device: Mapped["ClientDevice"] = relationship(back_populates="tokens")


class ConfigBundle(Base):
    __tablename__ = "config_bundles"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_id: Mapped[int] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"))
    version: Mapped[str] = mapped_column(String(64), index=True)
    payload_json: Mapped[str] = mapped_column(String)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )

    node: Mapped["Node"] = relationship()


class AlertEvent(Base):
    __tablename__ = "alert_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_id: Mapped[int | None] = mapped_column(
        ForeignKey("nodes.id", ondelete="SET NULL"), nullable=True
    )
    line_id: Mapped[int | None] = mapped_column(
        ForeignKey("lines.id", ondelete="SET NULL"), nullable=True
    )
    level: Mapped[str] = mapped_column(String(16))
    type: Mapped[str] = mapped_column(String(64))
    message: Mapped[str] = mapped_column(String(512))
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )


class FlowStat(Base):
    __tablename__ = "flow_stats"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_id: Mapped[int] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"))
    line_id: Mapped[int | None] = mapped_column(
        ForeignKey("lines.id", ondelete="SET NULL"), nullable=True
    )
    window_start: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), index=True)
    window_seconds: Mapped[int] = mapped_column(Integer)
    bytes_in: Mapped[int] = mapped_column(Integer, default=0)
    bytes_out: Mapped[int] = mapped_column(Integer, default=0)
    active_conns: Mapped[int] = mapped_column(Integer, default=0)


class NodeTrafficSample(Base):
    __tablename__ = "node_traffic_samples"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_id: Mapped[int] = mapped_column(ForeignKey("nodes.id", ondelete="CASCADE"), index=True)
    sampled_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), index=True)
    window_seconds: Mapped[int] = mapped_column(Integer, default=300)
    bytes_in: Mapped[int] = mapped_column(Integer, default=0)
    bytes_out: Mapped[int] = mapped_column(Integer, default=0)
    iface: Mapped[str | None] = mapped_column(String(64), nullable=True)


class PlatformUser(Base):
    __tablename__ = "platform_users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    password_hash: Mapped[str | None] = mapped_column(String(255), nullable=True)
    role: Mapped[str] = mapped_column(String(32), default="operator")
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )


class PlatformSetting(Base):
    __tablename__ = "platform_settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value_json: Mapped[str] = mapped_column(Text)
    updated_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )


class OperationLog(Base):
    __tablename__ = "operation_logs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(64))
    action: Mapped[str] = mapped_column(String(64))
    target: Mapped[str] = mapped_column(String(128))
    detail: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc)
    )
