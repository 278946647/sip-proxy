#!/usr/bin/env python3
"""Answer: can fleet upgrade from product version A to B under same_major_only policy?"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "docs" / "releases" / "VERSION_MATRIX.json"


def parse_semver(v: str) -> tuple[int, int, int]:
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)$", v.strip())
    if not m:
        raise SystemExit(f"invalid version: {v}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def find(matrix: dict, version: str) -> dict | None:
    version = version.lstrip("v")
    for row in matrix.get("releases") or []:
        if str(row.get("version")) == version:
            return row
    return None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--from", dest="from_v", required=True)
    p.add_argument("--to", dest="to_v", required=True)
    args = p.parse_args()

    matrix = json.loads(MATRIX.read_text(encoding="utf-8"))
    policy = (matrix.get("policy") or {}).get("upgrade")
    a = parse_semver(args.from_v)
    b = parse_semver(args.to_v)
    from_s = args.from_v.lstrip("v")
    to_s = args.to_v.lstrip("v")

    print(f"policy: {policy}")
    print(f"query: {from_s} -> {to_s}")

    if a == b:
        print("RESULT: ALLOWED (same version)")
        return 0

    if a > b:
        print("RESULT: DENIED (downgrade not managed by this tool)")
        return 1

    if policy == "same_major_only" and a[0] != b[0]:
        to_row = find(matrix, to_s)
        path = (to_row or {}).get("upgrade_path") or {}
        bridge = path.get("bridge")
        mig = path.get("migration_doc")
        print("RESULT: DENIED (cross-major direct upgrade forbidden)")
        if bridge:
            print(f"  bridge version: {bridge}  (upgrade {from_s} -> {bridge} -> {to_s})")
        if mig:
            print(f"  migration_doc: {mig}")
        if not bridge and not mig:
            print("  no bridge/migration_doc in matrix for target — do not ship")
        return 1

    to_row = find(matrix, to_s)
    if not to_row:
        print(f"RESULT: DENIED (target {to_s} not in VERSION_MATRIX.json)")
        return 1
    if to_row.get("status") == "eol":
        print("RESULT: DENIED (target is eol)")
        return 1
    if to_row.get("status") == "planned":
        print("RESULT: DENIED (target is planned, not released)")
        return 1

    from_row = find(matrix, from_s)
    if from_row is None:
        print(f"WARN: source {from_s} not in matrix; allowing within major by policy only")
    elif from_row.get("status") == "eol":
        print("WARN: source marked eol — prefer migrate via documented path")

    floors = to_row.get("floors") or {}
    print("RESULT: ALLOWED (same major)")
    print(f"  target floors: {floors}")
    print(f"  target components: {to_row.get('components')}")
    print(f"  client channel: {(to_row.get('channels') or {}).get('client_runtime')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
