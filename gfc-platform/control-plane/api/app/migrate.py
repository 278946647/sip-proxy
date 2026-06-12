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
                    proxy_mode VARCHAR(32) DEFAULT 'gateway',
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


async def migrate_sqlite(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await conn.run_sync(_migrate_sync)
