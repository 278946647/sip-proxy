from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import requests

from .version import AGENT_VERSION


@dataclass
class ClientState:
    device_id: int
    device_key: str
    client_token: str
    line_id: int
    tid: str
    applied_version: str | None = None


class ControlPlaneClient:
    def __init__(self, server: str, token: str | None = None) -> None:
        self.server = server.rstrip("/")
        self.token = token
        self._headers = {"Authorization": f"Bearer {token}"} if token else {}

    def activate(
        self,
        line_code_b32: str,
        device_name: str,
        lan_mac: str | None,
        device_id: str | None,
        proxy_mode: str,
    ) -> ClientState:
        resp = requests.post(
            f"{self.server}/clients/activate",
            json={
                "line_code_b32": line_code_b32,
                "device_name": device_name,
                "lan_mac": lan_mac,
                "device_id": device_id,
                "agent_version": AGENT_VERSION,
                "proxy_mode": proxy_mode,
            },
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()
        return ClientState(
            device_id=data["device_id"],
            device_key=data["device_key"],
            client_token=data["client_token"],
            line_id=data["line_id"],
            tid=data["tid"],
        )

    def heartbeat(
        self,
        metrics: dict[str, Any],
        device_name: str | None,
        reverse_ssh_port: int | None,
        proxy_mode: str | None,
    ) -> None:
        resp = requests.post(
            f"{self.server}/clients/heartbeat",
            headers=self._headers,
            json={
                "metrics": metrics,
                "device_name": device_name,
                "agent_version": AGENT_VERSION,
                "reverse_ssh_port": reverse_ssh_port,
                "proxy_mode": proxy_mode,
            },
            timeout=15,
        )
        resp.raise_for_status()

    def pull_config(self) -> dict[str, Any]:
        resp = requests.get(
            f"{self.server}/clients/me/config",
            headers=self._headers,
            timeout=30,
        )
        resp.raise_for_status()
        return resp.json()

    def ack_config(self, version: str, status: str, message: str | None = None) -> None:
        resp = requests.post(
            f"{self.server}/clients/me/config/ack",
            headers=self._headers,
            json={"version": version, "status": status, "message": message},
            timeout=15,
        )
        resp.raise_for_status()

    def check_reachable(self) -> bool:
        try:
            r = requests.get(f"{self.server}/healthz", timeout=5)
            return r.status_code == 200
        except requests.RequestException:
            return False
