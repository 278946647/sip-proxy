from __future__ import annotations

from typing import Any


def render_mosdns_config(payload: dict[str, Any]) -> str:
    dns = payload.get("dns") or {}
    domestic = (dns.get("domesticServer") or "223.5.5.5").strip()
    intl = (dns.get("intlServer") or "1.1.1.1").strip()
    # mosdns listens locally; sing-box routes intl DNS via proxy outbound.
    return f"""log:
  level: info

plugins:
  - tag: forward_domestic
    type: forward
    args:
      upstreams:
        - addr: "{domestic}"

  - tag: forward_intl
    type: forward
    args:
      upstreams:
        - addr: "{intl}"

  - tag: cn_domains
    type: domain_set
    args:
      files:
        - /etc/gfc-client/mosdns/cn-domains.txt

  - tag: sequence_main
    type: sequence
    args:
      - matches:
          - qname $cn_domains
        exec: forward_domestic
      - exec: forward_intl

  - tag: udp_server
    type: udp_server
    args:
      entry: sequence_main
      listen: 127.0.0.1:5335

  - tag: tcp_server
    type: tcp_server
    args:
      entry: sequence_main
      listen: 127.0.0.1:5335
"""
