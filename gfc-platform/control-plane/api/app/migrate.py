"""Lightweight SQLite migrations for dev (add missing columns)."""
from __future__ import annotations

from sqlalchemy import inspect, text
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import AsyncEngine


def _table_exists(sync_conn: Connection, table: str) -> bool:
    return table in inspect(sync_conn).get_table_names()


def _cols(sync_conn: Connection, table: str) -> set[str]:
    return {c["name"] for c in inspect(sync_conn).get_columns(table)}


def _migrate_sync(sync_conn: Connection) -> None:
    if sync_conn.dialect.name != "sqlite":
        return

    node_cols = {
        "country": "ALTER TABLE nodes ADD COLUMN country VARCHAR(64)",
        "connect_mode": "ALTER TABLE nodes ADD COLUMN connect_mode VARCHAR(32) DEFAULT 'ethernet'",
        "vpn_config_json": "ALTER TABLE nodes ADD COLUMN vpn_config_json TEXT",
        "last_metrics_json": "ALTER TABLE nodes ADD COLUMN last_metrics_json TEXT",
        "agent_version": "ALTER TABLE nodes ADD COLUMN agent_version VARCHAR(32)",
        "static_routes_json": "ALTER TABLE nodes ADD COLUMN static_routes_json TEXT",
        "reality_config_json": "ALTER TABLE nodes ADD COLUMN reality_config_json TEXT",
    }
    line_cols = {
        "tid": "ALTER TABLE lines ADD COLUMN tid VARCHAR(64)",
        "country": "ALTER TABLE lines ADD COLUMN country VARCHAR(64) DEFAULT ''",
        "bandwidth_mbps": "ALTER TABLE lines ADD COLUMN bandwidth_mbps INTEGER DEFAULT 5",
        "channel": "ALTER TABLE lines ADD COLUMN channel VARCHAR(128) DEFAULT ''",
        "remark": "ALTER TABLE lines ADD COLUMN remark TEXT",
        "socks_remark": "ALTER TABLE lines ADD COLUMN socks_remark TEXT",
        "status": "ALTER TABLE lines ADD COLUMN status VARCHAR(32) DEFAULT 'active'",
        "is_enabled": "ALTER TABLE lines ADD COLUMN is_enabled BOOLEAN DEFAULT 1",
        "created_by": "ALTER TABLE lines ADD COLUMN created_by VARCHAR(64) DEFAULT 'admin'",
        "created_at": "ALTER TABLE lines ADD COLUMN created_at DATETIME",
        "line_type": "ALTER TABLE lines ADD COLUMN line_type VARCHAR(32) DEFAULT 'client'",
        "client_uuid": "ALTER TABLE lines ADD COLUMN client_uuid VARCHAR(64)",
        "line_code_b32": "ALTER TABLE lines ADD COLUMN line_code_b32 TEXT",
        "flow_stats_enabled": "ALTER TABLE lines ADD COLUMN flow_stats_enabled BOOLEAN DEFAULT 1",
    }
    node_traffic_cols = {
        "traffic_monitor_iface": "ALTER TABLE nodes ADD COLUMN traffic_monitor_iface VARCHAR(64)",
        "traffic_billing_start_at": "ALTER TABLE nodes ADD COLUMN traffic_billing_start_at DATETIME",
        "traffic_billing_cycle_days": "ALTER TABLE nodes ADD COLUMN traffic_billing_cycle_days INTEGER DEFAULT 30",
        "traffic_monthly_quota_gb": "ALTER TABLE nodes ADD COLUMN traffic_monthly_quota_gb INTEGER",
        "traffic_correction_bytes": "ALTER TABLE nodes ADD COLUMN traffic_correction_bytes INTEGER DEFAULT 0",
        "traffic_pending_bytes_in": "ALTER TABLE nodes ADD COLUMN traffic_pending_bytes_in INTEGER DEFAULT 0",
        "traffic_pending_bytes_out": "ALTER TABLE nodes ADD COLUMN traffic_pending_bytes_out INTEGER DEFAULT 0",
        "traffic_last_sample_at": "ALTER TABLE nodes ADD COLUMN traffic_last_sample_at DATETIME",
    }
    socks_cols = {
        "remark": "ALTER TABLE socks_profiles ADD COLUMN remark TEXT",
        "country": "ALTER TABLE socks_profiles ADD COLUMN country VARCHAR(128)",
        "channel": "ALTER TABLE socks_profiles ADD COLUMN channel VARCHAR(128)",
        "is_healthy": "ALTER TABLE socks_profiles ADD COLUMN is_healthy BOOLEAN DEFAULT 1",
        "created_at": "ALTER TABLE socks_profiles ADD COLUMN created_at DATETIME",
    }
    alert_cols = {
        "line_id": "ALTER TABLE alert_events ADD COLUMN line_id INTEGER",
    }
    user_cols = {
        "password_hash": "ALTER TABLE platform_users ADD COLUMN password_hash VARCHAR(255)",
    }

    if _table_exists(sync_conn, "nodes"):
        existing = _cols(sync_conn, "nodes")
        for col, sql in node_cols.items():
            if col not in existing:
                sync_conn.execute(text(sql))
        existing = _cols(sync_conn, "nodes")
        for col, sql in node_traffic_cols.items():
            if col not in existing:
                sync_conn.execute(text(sql))

    if _table_exists(sync_conn, "lines"):
        existing = _cols(sync_conn, "lines")
        for col, sql in line_cols.items():
            if col not in existing:
                sync_conn.execute(text(sql))
        sync_conn.execute(
            text(
                "UPDATE lines SET tid = 'TID-legacy-' || id "
                "WHERE tid IS NULL OR tid = ''"
            )
        )

    if _table_exists(sync_conn, "socks_profiles"):
        existing = _cols(sync_conn, "socks_profiles")
        for col, sql in socks_cols.items():
            if col not in existing:
                sync_conn.execute(text(sql))

    if _table_exists(sync_conn, "alert_events"):
        existing = _cols(sync_conn, "alert_events")
        for col, sql in alert_cols.items():
            if col not in existing:
                sync_conn.execute(text(sql))

    if _table_exists(sync_conn, "platform_users"):
        existing = _cols(sync_conn, "platform_users")
        for col, sql in user_cols.items():
            if col not in existing:
                sync_conn.execute(text(sql))

    client_device_cols = {
        "routing_scheme": (
            "ALTER TABLE client_devices ADD COLUMN routing_scheme VARCHAR(32) DEFAULT 'split'"
        ),
        "reverse_http_port": "ALTER TABLE client_devices ADD COLUMN reverse_http_port INTEGER",
        "ssh_public_key": "ALTER TABLE client_devices ADD COLUMN ssh_public_key TEXT",
        "reverse_ssh_session_expires_at": (
            "ALTER TABLE client_devices ADD COLUMN reverse_ssh_session_expires_at DATETIME"
        ),
        "reverse_ssh_session_targets": (
            "ALTER TABLE client_devices ADD COLUMN reverse_ssh_session_targets TEXT"
        ),
        "reverse_ssh_tunnel_reported_at": (
            "ALTER TABLE client_devices ADD COLUMN reverse_ssh_tunnel_reported_at DATETIME"
        ),
        "name_source": (
            "ALTER TABLE client_devices ADD COLUMN name_source VARCHAR(16) DEFAULT 'auto'"
        ),
        "binding_revoked_at": (
            "ALTER TABLE client_devices ADD COLUMN binding_revoked_at DATETIME"
        ),
        "code_cleared_at": (
            "ALTER TABLE client_devices ADD COLUMN code_cleared_at DATETIME"
        ),
        "pending_device_command_json": (
            "ALTER TABLE client_devices ADD COLUMN pending_device_command_json TEXT"
        ),
    }
    if _table_exists(sync_conn, "client_devices"):
        existing = _cols(sync_conn, "client_devices")
        for col, sql in client_device_cols.items():
            if col not in existing:
                sync_conn.execute(text(sql))
        sync_conn.execute(
            text(
                "UPDATE client_devices SET reverse_http_port = reverse_ssh_port + 1 "
                "WHERE reverse_ssh_port IS NOT NULL AND reverse_http_port IS NULL"
            )
        )

    if not _table_exists(sync_conn, "client_devices"):
        sync_conn.execute(
            text(
                """
                CREATE TABLE client_devices (
                    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                    device_key VARCHAR(64) NOT NULL,
                    name VARCHAR(128) NOT NULL,
                    lan_mac VARCHAR(32),
                    device_id VARCHAR(32),
                    line_id INTEGER,
                    reverse_ssh_port INTEGER,
                    reverse_http_port INTEGER,
                    ssh_public_key TEXT,
                    reverse_ssh_session_expires_at DATETIME,
                    reverse_ssh_session_targets TEXT,
                    reverse_ssh_tunnel_reported_at DATETIME,
                    proxy_mode VARCHAR(32) DEFAULT 'gateway',
                    routing_scheme VARCHAR(32) DEFAULT 'split',
                    name_source VARCHAR(16) DEFAULT 'auto',
                    binding_revoked_at DATETIME,
                    code_cleared_at DATETIME,
                    pending_device_command_json TEXT,
                    agent_version VARCHAR(32),
                    last_seen_at DATETIME,
                    last_metrics_json TEXT,
                    is_active BOOLEAN DEFAULT 1,
                    created_at DATETIME,
                    FOREIGN KEY(line_id) REFERENCES lines (id) ON DELETE SET NULL,
                    UNIQUE (device_key),
                    UNIQUE (line_id)
                )
                """
            )
        )

    if not _table_exists(sync_conn, "client_tokens"):
        sync_conn.execute(
            text(
                """
                CREATE TABLE client_tokens (
                    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                    device_id INTEGER NOT NULL,
                    token_hash VARCHAR(128) NOT NULL,
                    created_at DATETIME,
                    expires_at DATETIME,
                    revoked_at DATETIME,
                    FOREIGN KEY(device_id) REFERENCES client_devices (id) ON DELETE CASCADE,
                    UNIQUE (token_hash)
                )
                """
            )
        )

    if not _table_exists(sync_conn, "node_traffic_samples"):
        sync_conn.execute(
            text(
                """
                CREATE TABLE node_traffic_samples (
                    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                    node_id INTEGER NOT NULL,
                    sampled_at DATETIME NOT NULL,
                    window_seconds INTEGER DEFAULT 300,
                    bytes_in INTEGER DEFAULT 0,
                    bytes_out INTEGER DEFAULT 0,
                    iface VARCHAR(64),
                    FOREIGN KEY(node_id) REFERENCES nodes (id) ON DELETE CASCADE
                )
                """
            )
        )
        sync_conn.execute(
            text(
                "CREATE INDEX IF NOT EXISTS idx_node_traffic_node_ts "
                "ON node_traffic_samples(node_id, sampled_at)"
            )
        )
    elif _table_exists(sync_conn, "node_traffic_samples"):
        sync_conn.execute(
            text(
                "CREATE INDEX IF NOT EXISTS idx_node_traffic_node_ts "
                "ON node_traffic_samples(node_id, sampled_at)"
            )
        )

    if not _table_exists(sync_conn, "released_reverse_ports"):
        sync_conn.execute(
            text(
                """
                CREATE TABLE released_reverse_ports (
                    port INTEGER NOT NULL PRIMARY KEY,
                    former_device_id INTEGER,
                    released_at DATETIME,
                    released_until DATETIME
                )
                """
            )
        )

    if not _table_exists(sync_conn, "client_device_tombstones"):
        sync_conn.execute(
            text(
                """
                CREATE TABLE client_device_tombstones (
                    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                    device_key VARCHAR(64) NOT NULL,
                    former_device_id INTEGER,
                    former_name VARCHAR(128),
                    lan_mac VARCHAR(32),
                    retired_at DATETIME,
                    retired_by VARCHAR(64),
                    reclaimed_at DATETIME,
                    UNIQUE (device_key)
                )
                """
            )
        )


async def migrate_sqlite(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await conn.run_sync(_migrate_sync)
