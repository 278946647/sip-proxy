from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import requests

from .server_url import normalize_server_url, parse_server_url_list
from .version import AGENT_VERSION


@dataclass
class NodeState:
    node_id: int
    node_key: str
    node_token: str
    applied_version: str | None = None


class ControlPlaneClient:
    def __init__(self, servers: str | list[str], token: str | None = None) -> None:
        if isinstance(servers, str):
            self.servers = parse_server_url_list(servers)
        else:
            self.servers = [normalize_server_url(s) for s in servers]
        if not self.servers:
            raise ValueError("at least one control plane SERVER_URL is required")
        self.token = token
        self._headers = {"Authorization": f"Bearer {token}"} if token else {}
        self._active_idx = 0

    @property
    def server(self) -> str:
        return self.servers[self._active_idx]

    def _request(self, method: str, path: str, **kwargs: Any) -> requests.Response:
        last_exc: requests.RequestException | None = None
        for idx, base in enumerate(self.servers):
            try:
                resp = requests.request(method, f"{base}{path}", **kwargs)
                resp.raise_for_status()
                if idx != self._active_idx:
                    self._active_idx = idx
                return resp
            except requests.RequestException as exc:
                last_exc = exc
        if last_exc is not None:
            raise last_exc
        raise RuntimeError("no control plane URL configured")

    def activate(
        self,
        bootstrap_token: str,
        node_name: str,
        region: str,
        public_ip: str | None = None,
    ) -> NodeState:
        resp = self._request(
            "POST",
            "/nodes/activate",
            json={
                "bootstrap_token": bootstrap_token,
                "node_name": node_name,
                "region": region,
                "public_ip": public_ip,
                "agent_version": AGENT_VERSION,
            },
            timeout=20,
        )
        data = resp.json()
        return NodeState(
            node_id=data["node_id"],
            node_key=data["node_key"],
            node_token=data["node_token"],
        )

    def heartbeat(self, metrics: dict[str, Any], node_name: str, public_ip: str | None) -> None:
        self._request(
            "POST",
            "/nodes/heartbeat",
            headers=self._headers,
            json={
                "public_ip": public_ip,
                "metrics": metrics,
                "node_name": node_name,
                "agent_version": AGENT_VERSION,
            },
            timeout=15,
        )

    def pull_config(self) -> dict[str, Any]:
        resp = self._request(
            "GET",
            "/nodes/me/config",
            headers=self._headers,
            timeout=30,
        )
        return resp.json()

    def ack_config(self, version: str, status: str, message: str | None = None) -> None:
        self._request(
            "POST",
            "/nodes/me/config/ack",
            headers=self._headers,
            json={"version": version, "status": status, "message": message},
            timeout=15,
        )

    def report_live_resolve(self, body: dict[str, Any]) -> dict[str, Any]:
        resp = self._request(
            "POST",
            "/nodes/me/live-resolve",
            headers=self._headers,
            json=body,
            timeout=30,
        )
        return resp.json()

    def check_reachable(self) -> bool:
        for base in self.servers:
            try:
                r = requests.get(f"{base}/healthz", timeout=5)
                if r.status_code == 200:
                    self._active_idx = self.servers.index(base)
                    return True
            except requests.RequestException:
                continue
        return False
