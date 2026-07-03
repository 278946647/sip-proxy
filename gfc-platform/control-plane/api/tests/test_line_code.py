import os
import sys
import unittest
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.client_config import build_line_code_payload, line_code_fingerprint, refresh_line_code
from app.line_code import decode_line_code
from app.models import Line, Node


def _client_line(**overrides) -> Line:
    defaults = {
        "tid": "TID-20260703-AAAAAA",
        "name": "test",
        "source_cidrs": "",
        "node_id": 1,
        "line_type": "client",
        "client_uuid": str(uuid.uuid4()),
    }
    defaults.update(overrides)
    return Line(id=overrides.get("id", 1), **{k: v for k, v in defaults.items() if k != "id"})


def _node() -> Node:
    return Node(
        id=5,
        node_key="nk",
        name="hk-node-5",
        region="hk",
        public_ip="1.2.3.4",
    )


class LineCodeTests(unittest.TestCase):
    def test_recreate_produces_different_code(self) -> None:
        node = _node()
        line_a = _client_line(id=1, tid="TID-20260623-OLD", client_uuid="uuid-old")
        line_b = _client_line(id=2, tid="TID-20260703-NEW", client_uuid="uuid-new")
        code_a = refresh_line_code(line_a, node)
        code_b = refresh_line_code(line_b, node)
        self.assertNotEqual(code_a, code_b)

    def test_sync_heals_stale_cached_column(self) -> None:
        node = _node()
        line = _client_line(client_uuid="current-uuid")
        stale = refresh_line_code(
            _client_line(client_uuid="stale-uuid"),
            node,
        )
        line.line_code_b32 = stale
        fresh = refresh_line_code(line, node)
        self.assertNotEqual(stale, fresh)
        payload = decode_line_code(fresh)
        self.assertEqual(payload.get("uuid"), "current-uuid")

    def test_fingerprint_changes_with_payload(self) -> None:
        node = _node()
        a = refresh_line_code(_client_line(client_uuid="a"), node)
        b = refresh_line_code(_client_line(client_uuid="b"), node)
        self.assertNotEqual(line_code_fingerprint(a), line_code_fingerprint(b))

    def test_payload_includes_binding_fields(self) -> None:
        node = _node()
        line = _client_line(id=7, client_uuid="u-1")
        payload = build_line_code_payload(line, node)
        self.assertEqual(payload["lineId"], 7)
        self.assertEqual(payload["uuid"], "u-1")
        self.assertEqual(payload["nodeId"], 5)


if __name__ == "__main__":
    unittest.main()
