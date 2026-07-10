from __future__ import annotations

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field, model_validator

from .socks_parse import parse_socks_address


class ActivateRequest(BaseModel):
    bootstrap_token: str = Field(min_length=1)
    node_name: str = Field(min_length=1, max_length=128)
    region: str = Field(min_length=1, max_length=64)
    public_ip: str | None = None
    agent_version: str | None = None
    hostname: str | None = None


class ActivateResponse(BaseModel):
    node_id: int
    node_key: str
    node_token: str


class HeartbeatRequest(BaseModel):
    public_ip: str | None = None
    metrics: dict[str, Any] | None = None
    node_name: str | None = Field(default=None, max_length=128)
    agent_version: str | None = None


class StaticRouteIn(BaseModel):
    """Return-path route on forward node (traffic back to VyOS / customer CIDR)."""

    prefix: str = Field(min_length=1, description="Destination CIDR, e.g. 10.0.0.0/24")
    next_hop: str | None = Field(default=None, description="VyOS or tunnel gateway IP")
    device: str | None = Field(default=None, description="egress interface, e.g. eth1 or tun0")
    comment: str | None = None


class NodeUpdateIn(BaseModel):
    name: str | None = Field(default=None, max_length=128)
    region: str | None = None
    country: str | None = None
    connect_mode: str | None = Field(default=None, pattern="^(ethernet|openvpn)$")
    vpn_config: dict[str, Any] | None = None
    static_routes: list[StaticRouteIn] | None = None
    is_active: bool | None = None


class NodeVpnConfigIn(BaseModel):
    enabled: bool = True
    auth_mode: str = Field(
        default="pki",
        pattern="^(pki|static_key)$",
        description="pki = CA/client cert (TLS); static_key = OpenVPN pre-shared key (VyOS 1.2)",
    )
    remote: str = Field(min_length=1, description="VyOS / backbone WAN address")
    port: int = 1194
    proto: str = "udp"
    dev: str = "tun0"
    ca: str | None = None
    cert: str | None = None
    key: str | None = None
    static_key: str | None = Field(
        default=None,
        description="OpenVPN static key file content (BEGIN OpenVPN Static key V1)",
    )
    tls_auth: str | None = None
    remote_networks: list[str] = Field(
        default_factory=list,
        description="Customer/backbone CIDRs behind VyOS (auto return routes on node)",
    )
    tunnel_network: str | None = Field(
        default=None,
        description="Point-to-point tunnel subnet, e.g. 10.255.0.0/30 (VyOS export only)",
    )
    auto_static_routes: bool = Field(
        default=True,
        description="Merge line source_cidrs + remote_networks into node static return routes",
    )
    extra_config: str | None = None

    @model_validator(mode="after")
    def _validate_auth_material(self) -> "NodeVpnConfigIn":
        mode = (self.auth_mode or "pki").strip()
        if mode == "static_key":
            if not (self.static_key or "").strip():
                raise ValueError("static_key 模式下请填写 OpenVPN 静态密钥")
            return self
        for field_name, label in (("ca", "CA 证书"), ("cert", "客户端证书"), ("key", "客户端私钥")):
            if not (getattr(self, field_name) or "").strip():
                raise ValueError(f"PKI 模式下请填写{label}")
        return self


class VpnPkiIssueIn(BaseModel):
    common_name: str | None = Field(
        default=None,
        description="OpenVPN client CN; default gfc-node-<id>",
    )
    save: bool = Field(default=True, description="Write cert into node VPN config and push")


class VpnStaticKeyIssueIn(BaseModel):
    save: bool = Field(default=True, description="Write static key into node VPN config and push")


class HeartbeatResponse(BaseModel):
    ok: bool = True
    server_time: dt.datetime


class SocksProfileIn(BaseModel):
    """Either provide address (username:password@host:port) or host+port fields."""

    name: str
    address: str | None = Field(
        default=None,
        description="Optional combined URI: username:password@IP:Port",
    )
    host: str | None = None
    port: int | None = None
    username: str | None = None
    password: str | None = None
    country: str | None = None
    channel: str | None = None
    remark: str | None = None

    @model_validator(mode="after")
    def _resolve_address(self) -> "SocksProfileIn":
        if self.address:
            p = parse_socks_address(self.address)
            object.__setattr__(self, "host", p["host"])
            object.__setattr__(self, "port", p["port"])
            if p.get("username"):
                object.__setattr__(self, "username", p["username"])
            if p.get("password"):
                object.__setattr__(self, "password", p["password"])
        if not self.host or self.port is None:
            raise ValueError("请填写代理地址 (username:password@IP:Port) 或 host+port")
        return self


class SocksProfileUpdate(BaseModel):
    name: str | None = None
    address: str | None = None
    host: str | None = None
    port: int | None = None
    username: str | None = None
    password: str | None = None
    country: str | None = None
    channel: str | None = None
    remark: str | None = None


class SocksProfileOut(BaseModel):
    id: int
    name: str
    host: str
    port: int
    username: str | None = None
    password: str | None = None
    country: str | None = None
    channel: str | None = None
    remark: str | None = None
    address_display: str = ""
    is_healthy: bool = True
    line_binding_count: int = 0
    created_at: dt.datetime | None = None


class LineCreateIn(BaseModel):
    name: str | None = None
    source_cidrs: list[str] = Field(default_factory=list)
    node_id: int
    socks_profile_id: int | None = None
    line_type: str = Field(default="client", pattern="^(client|forward)$")
    country: str = ""
    bandwidth_mbps: int = Field(default=5, ge=1, le=10000)
    remark: str | None = None
    socks_remark: str | None = None
    created_by: str = "admin"


class LineUpdateIn(BaseModel):
    remark: str | None = None
    socks_remark: str | None = None
    status: str | None = None
    is_enabled: bool | None = None
    bandwidth_mbps: int | None = Field(default=None, ge=1, le=10000)
    country: str | None = None
    source_cidrs: list[str] | None = None
    socks_profile_id: int | None = None
    node_id: int | None = None
    name: str | None = None
    flow_stats_enabled: bool | None = None


class LineListItem(BaseModel):
    id: int
    tid: str
    name: str
    node_id: int
    node_name: str
    country: str
    bandwidth_mbps: int
    remark: str | None
    is_enabled: bool
    status: str
    created_at: dt.datetime
    socks_profile_id: int | None
    socks_name: str | None
    line_type: str
    client_device_id: int | None = None
    client_device_name: str | None = None


class LineDetailOut(LineListItem):
    source_cidrs: list[str]
    socks_remark: str | None
    created_by: str
    socks_host: str | None = None
    socks_port: int | None = None
    socks_username: str | None = None
    socks_password: str | None = None
    client_socks_display: str = "N/A"
    current_config_version: str | None = None
    client_uuid: str | None = None
    line_code_b32: str | None = None
    flow_stats_enabled: bool = True


class LineOut(BaseModel):
    id: int
    tid: str
    name: str
    source_cidrs: list[str]
    node_id: int
    socks_profile_id: int


class ConfigBundleOut(BaseModel):
    version: str
    payload: dict[str, Any]


class ConfigAckIn(BaseModel):
    version: str
    status: str = Field(pattern="^(applied|failed)$")
    message: str | None = None


class DashboardOut(BaseModel):
    node_total: int
    node_online: int
    line_total: int
    line_active: int
    socks_total: int
    socks_online: int
    socks_offline: int
    alert_open: int
    socks_alert_open: int = 0


class AlertOut(BaseModel):
    id: int
    node_id: int | None
    line_id: int | None
    level: str
    type: str
    message: str
    created_at: dt.datetime


class FlowStatOut(BaseModel):
    id: int
    node_id: int
    line_id: int | None
    window_start: dt.datetime
    window_seconds: int
    bytes_in: int
    bytes_out: int
    active_conns: int


class NodeTrafficBillingIn(BaseModel):
    billing_cycle_start_at: dt.datetime | None = None
    billing_cycle_days: int | None = Field(default=None, ge=1, le=365)
    monthly_quota_gb: int | None = Field(default=None, ge=1, le=102400)
    correction_bytes: int | None = None
    monitor_iface: str | None = Field(default=None, max_length=64)


class NodeTrafficOverviewOut(BaseModel):
    node_id: int
    node_name: str
    country: str | None
    public_ip: str | None
    online: bool
    last_24h_bytes: int
    recent_increment_bytes: int
    billing_period_bytes: int
    billing_cycle_start_at: dt.datetime | None
    billing_cycle_end_at: dt.datetime | None
    billing_cycle_days: int
    monthly_quota_gb: int | None
    quota_used_percent: float | None
    correction_bytes: int
    monitor_iface: str | None
    status: str
    last_sample_at: dt.datetime | None


class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1)


class LoginOut(BaseModel):
    token: str
    user: "UserOut"
    must_change_password: bool = False


class SetupHintOut(BaseModel):
    username: str = "admin"
    initial_password: str | None = None
    password_change_required: bool = False


class InitialPasswordChangeIn(BaseModel):
    new_password: str = Field(min_length=8, max_length=128)
    confirm_password: str = Field(min_length=8, max_length=128)


class ChangePasswordIn(BaseModel):
    old_password: str = Field(min_length=1)
    new_password: str = Field(min_length=6, max_length=128)


class UserIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=6, max_length=128)
    role: str = Field(default="operator", pattern="^(admin|operator|auditor)$")


class UserUpdateIn(BaseModel):
    role: str | None = Field(default=None, pattern="^(admin|operator|auditor)$")
    is_active: bool | None = None
    password: str | None = Field(default=None, min_length=6, max_length=128)


class EmailSettingsIn(BaseModel):
    host: str = Field(min_length=1)
    port: int = Field(default=587, ge=1, le=65535)
    username: str | None = None
    password: str | None = None
    mail_from: str = Field(min_length=1)
    mail_to: str = Field(min_length=1)
    starttls: bool = False


class SecuritySettingsIn(BaseModel):
    confirm: bool = Field(
        default=False,
        description="Must be true — confirms admin understands impact (node sync / logout).",
    )
    bootstrap_tokens: str | None = Field(
        default=None,
        description="Comma-separated bootstrap tokens for new nodes; synced to forward nodes.",
    )
    auth_secret: str | None = Field(
        default=None,
        min_length=16,
        description="JWT signing secret; changing logs out all Web sessions.",
    )
    admin_password: str | None = Field(
        default=None,
        min_length=8,
        description="New password for admin user.",
    )


class UserPermissionsOut(BaseModel):
    actions: list[str]
    menus: list[str]
    can_remote_access: bool = False
    can_delete_structural: bool = False
    can_write_traffic_billing: bool = False


class UserOut(BaseModel):
    id: int
    username: str
    role: str
    is_active: bool
    created_at: dt.datetime
    permissions: UserPermissionsOut | None = None


class OperationLogOut(BaseModel):
    id: int
    username: str
    action: str
    target: str
    detail: str | None
    created_at: dt.datetime


class PaginatedLines(BaseModel):
    total: int
    items: list[LineListItem]


class ClientActivateIn(BaseModel):
    line_code_b32: str = Field(min_length=8)
    device_name: str = Field(min_length=1, max_length=128)
    lan_mac: str | None = None
    device_id: str | None = None
    agent_version: str | None = None
    proxy_mode: str = Field(default="gateway", pattern="^(gateway|bypass|transparent)$")


class ClientActivateResponse(BaseModel):
    device_id: int
    device_key: str
    client_token: str
    line_id: int
    tid: str


class ClientHeartbeatRequest(BaseModel):
    metrics: dict[str, Any] | None = None
    device_name: str | None = Field(default=None, max_length=128)
    agent_version: str | None = None
    reverse_ssh_port: int | None = None
    reverse_http_port: int | None = None
    ssh_public_key: str | None = None
    ssh_key_rotate: bool = False
    reverse_ssh_status: dict[str, Any] | None = None
    proxy_mode: str | None = Field(default=None, pattern="^(gateway|bypass|transparent)$")


class ClientRuntimeUpdateIn(BaseModel):
    proxy_mode: str | None = Field(default=None, pattern="^(gateway|bypass|transparent)$")
    routing_scheme: str | None = Field(default=None, pattern="^(split|global)$")


class ReverseSSHPortsOut(BaseModel):
    ssh: int | None = None
    http: int | None = None


class ReverseSSHCommandOut(BaseModel):
    enabled: bool = False
    host: str | None = None
    port: int = 212
    user: str | None = None
    expires_at: dt.datetime | None = None
    ports: ReverseSSHPortsOut | None = None
    targets: list[str] = Field(default_factory=list)


class ClientHeartbeatResponse(BaseModel):
    ok: bool = True
    server_time: dt.datetime
    reverse_ssh: ReverseSSHCommandOut | None = None
    webssh_authorized_key: str | None = None


class ClientConfigAckIn(BaseModel):
    version: str
    status: str = Field(pattern="^(applied|failed)$")
    message: str | None = None


class ClientDeviceUpdateIn(BaseModel):
    name: str | None = Field(default=None, max_length=128)
    line_id: int | None = None
    reverse_ssh_port: int | None = None
    proxy_mode: str | None = Field(default=None, pattern="^(gateway|bypass|transparent)$")
    routing_scheme: str | None = Field(default=None, pattern="^(split|global)$")
    is_active: bool | None = None


class ClientDeviceListItem(BaseModel):
    id: int
    name: str
    device_key: str
    lan_mac: str | None
    device_id: str | None
    line_id: int | None
    line_tid: str | None
    reverse_ssh_port: int | None
    reverse_http_port: int | None = None
    ssh_public_key_registered: bool = False
    reverse_ssh_session_state: str = "idle"
    proxy_mode: str
    routing_scheme: str = "split"
    online: bool
    management_state: str = "offline"
    service_state: str = "unknown"
    service_reason: str | None = None
    line_enabled: bool | None = None
    last_seen_at: dt.datetime | None
    agent_version: str | None
    created_at: dt.datetime


class ClientDeviceDetailOut(ClientDeviceListItem):
    metrics: dict[str, Any] | None = None
    line_name: str | None = None
    line_country: str | None = None
    node_name: str | None = None
    ssh_connect_url: str | None = None
    web_remote_url: str | None = None
    flash_remote_url: str | None = None


class ReverseSSHSessionIn(BaseModel):
    targets: list[str] = Field(default_factory=lambda: ["ssh"])
    ttl_seconds: int | None = Field(default=None, ge=60, le=7200)


class ReverseSSHSessionOut(BaseModel):
    state: str
    expires_at: dt.datetime | None = None
    tunnel_ready: bool = False
    ports: ReverseSSHPortsOut | None = None
    targets: list[str] = Field(default_factory=list)
    urls: dict[str, str | None] = Field(default_factory=dict)
    message: str | None = None


class PaginatedClientDevices(BaseModel):
    total: int
    items: list[ClientDeviceListItem]


LoginOut.model_rebuild()
