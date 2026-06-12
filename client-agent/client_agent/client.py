from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import requests

from .server_url import normalize_server_url, parse_server_url_list
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
        line_code_b32: str,
        device_name: str,
        lan_mac: str | None,
        device_id: str | None,
        proxy_mode: str,
    ) -> ClientState:
        resp = self._request(
            "POST",
            "/clients/activate",
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
        self._request(
            "POST",
            "/clients/heartbeat",
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

    def pull_config(self) -> dict[str, Any]:
        resp = self._request(
            "GET",
            "/clients/me/config",
            headers=self._headers,
            timeout=30,
        )
        return resp.json()

    def ack_config(self, version: str, status: str, message: str | None = None) -> None:
        self._request(
            "POST",
            "/clients/me/config/ack",
            headers=self._headers,
            json={"version": version, "status": status, "message": message},
            timeout=15,
        )

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
