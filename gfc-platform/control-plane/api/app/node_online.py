from __future__ import annotations

from .models import Node
from .settings import settings
from .timeutil import seconds_ago


def node_is_online(node: Node) -> bool:
    ago = seconds_ago(node.last_seen_at)
    return ago is not None and ago < settings.node_offline_threshold_seconds
