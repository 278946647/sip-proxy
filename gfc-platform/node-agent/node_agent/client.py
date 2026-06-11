from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import requests

from .version import AGENT_VERSION


@dataclass
class NodeState:
    node_id: int
    node_key: str
    node_token: str
    applied_version: str | None = None


class ControlPlaneClient:
    def __init__(self, server: str, token: str | None = None) -> None:
        self.server = server.rstrip("/")
        self.token = token
        self._headers = {"Authorization": f"Bearer {token}"} if token else {}

    def activate(
        self,
        bootstrap_token: str,
        node_name: str,
        region: str,
        public_ip: str | None = None,
    ) -> NodeState:
        resp = requests.post(
            f"{self.server}/nodes/activate",
            json={
                "bootstrap_token": bootstrap_token,
                "node_name": node_name,
                "region": region,
                "public_ip": public_ip,
                "agent_version": AGENT_VERSION,
            },
            timeout=20,
        )
        resp.raise_for_status()
        data = resp.json()
        return NodeState(
            node_id=data["node_id"],
            node_key=data["node_key"],
            node_token=data["node_token"],
        )

    def heartbeat(self, metrics: dict[str, Any], node_name: str, public_ip: str | None) -> None:
        resp = requests.post(
            f"{self.server}/nodes/heartbeat",
            headers=self._headers,
            json={
                "public_ip": public_ip,
                "metrics": metrics,
                "node_name": node_name,
                "agent_version": AGENT_VERSION,
            },
            timeout=15,
        )
        resp.raise_for_status()

    def pull_config(self) -> dict[str, Any]:
        resp = requests.get(
            f"{self.server}/nodes/me/config",
            headers=self._headers,
            timeout=30,
        )
        resp.raise_for_status()
        return resp.json()

    def ack_config(self, version: str, status: str, message: str | None = None) -> None:
        resp = requests.post(
            f"{self.server}/nodes/me/config/ack",
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
