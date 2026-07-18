#!/usr/bin/env python3
"""Validate docs/releases/VERSION_MATRIX.json against repo component versions."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "docs" / "releases" / "VERSION_MATRIX.json"
MAKEFILE = ROOT / "gfc-client" / "deploy" / "immortalwrt" / "package" / "Makefile"
NODE_VERSION = ROOT / "gfc-platform" / "node-agent" / "node_agent" / "version.py"
API_SETTINGS = ROOT / "gfc-platform" / "control-plane" / "api" / "app" / "settings.py"
CHANGELOG = ROOT / "docs" / "releases" / "CHANGELOG.md"


def parse_semver(v: str) -> tuple[int, int, int]:
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", v.strip())
    if not m:
        raise ValueError(f"expected MAJOR.MINOR.PATCH, got {v!r}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def read_gfc_client() -> str:
    text = MAKEFILE.read_text(encoding="utf-8")
    ver = re.search(r"^PKG_VERSION:=(.+)$", text, re.M)
    rel = re.search(r"^PKG_RELEASE:=(.+)$", text, re.M)
    if not ver or not rel:
        raise RuntimeError(f"cannot parse PKG_VERSION/PKG_RELEASE in {MAKEFILE}")
    return f"{ver.group(1).strip()}-r{rel.group(1).strip()}"


def read_node_agent() -> str:
    text = NODE_VERSION.read_text(encoding="utf-8")
    m = re.search(r'AGENT_VERSION\s*=\s*["\']([^"\']+)["\']', text)
    if not m:
        raise RuntimeError(f"cannot parse AGENT_VERSION in {NODE_VERSION}")
    return m.group(1)


def read_api_version() -> str:
    text = API_SETTINGS.read_text(encoding="utf-8")
    m = re.search(r'api_version:\s*str\s*=\s*["\']([^"\']+)["\']', text)
    if not m:
        raise RuntimeError(f"cannot parse api_version in {API_SETTINGS}")
    return m.group(1)


def find_release(matrix: dict, version: str) -> dict | None:
    for row in matrix.get("releases") or []:
        if str(row.get("version")) == version:
            return row
    return None


def check_upgrade_policy(matrix: dict, errors: list[str]) -> None:
    policy = (matrix.get("policy") or {}).get("upgrade")
    if policy != "same_major_only":
        errors.append(f"policy.upgrade must be same_major_only, got {policy!r}")

    for row in matrix.get("releases") or []:
        ver = str(row.get("version"))
        major, _, _ = parse_semver(ver)
        path = row.get("upgrade_path") or {}
        from_majors = path.get("from_majors") or []
        if path.get("from_any_in_major") and from_majors and major not in from_majors:
            errors.append(f"{ver}: from_any_in_major true but from_majors missing own major {major}")
        bridge = path.get("bridge")
        mig = path.get("migration_doc")
        if not path.get("from_any_in_major") and not bridge and not mig:
            if row.get("status") in ("current", "supported"):
                errors.append(
                    f"{ver}: status={row.get('status')} but no from_any_in_major "
                    f"and no bridge/migration_doc"
                )


def check_current_pins(matrix: dict, errors: list[str], warnings: list[str]) -> None:
    current = str((matrix.get("product") or {}).get("current") or "")
    if not current:
        errors.append("product.current is empty")
        return
    row = find_release(matrix, current)
    if not row:
        errors.append(f"product.current={current} has no releases[] row")
        return
    if row.get("status") not in ("current", "supported"):
        warnings.append(f"product.current={current} status is {row.get('status')!r}")

    comps = row.get("components") or {}
    repo_client = read_gfc_client()
    repo_node = read_node_agent()
    repo_api = read_api_version()

    pin_client = comps.get("gfc_client")
    pin_node = comps.get("node_agent")
    pin_api = comps.get("control_plane_api")

    if pin_client and pin_client != repo_client:
        errors.append(
            f"gfc_client mismatch: matrix={pin_client} Makefile={repo_client} "
            f"(bump PKG_RELEASE or update matrix together)"
        )
    if pin_node and pin_node != repo_node:
        errors.append(f"node_agent mismatch: matrix={pin_node} version.py={repo_node}")
    if pin_api and pin_api != repo_api:
        warnings.append(
            f"control_plane_api differs: matrix={pin_api} settings.py={repo_api} "
            f"(align on next release cut)"
        )

    if CHANGELOG.is_file():
        cl = CHANGELOG.read_text(encoding="utf-8")
        if f"[{current}]" not in cl and f"[v{current}]" not in cl:
            errors.append(f"CHANGELOG.md missing section for [{current}]")
    else:
        errors.append(f"missing {CHANGELOG}")


def check_monotonic_versions(matrix: dict, errors: list[str]) -> None:
    seen: list[tuple[int, int, int]] = []
    for row in matrix.get("releases") or []:
        try:
            seen.append(parse_semver(str(row["version"])))
        except (KeyError, ValueError) as e:
            errors.append(str(e))
            return
    if len(seen) != len(set(seen)):
        errors.append("duplicate version rows in releases[]")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-repo-pins", action="store_true")
    args = parser.parse_args()

    if not MATRIX.is_file():
        print(f"ERROR: missing {MATRIX}", file=sys.stderr)
        return 1

    matrix = json.loads(MATRIX.read_text(encoding="utf-8"))
    errors: list[str] = []
    warnings: list[str] = []

    if (matrix.get("schema_version") or 0) < 1:
        errors.append("schema_version must be >= 1")

    check_upgrade_policy(matrix, errors)
    check_monotonic_versions(matrix, errors)
    if not args.skip_repo_pins:
        try:
            check_current_pins(matrix, errors, warnings)
        except Exception as e:  # noqa: BLE001
            errors.append(str(e))

    for w in warnings:
        print(f"WARN: {w}")
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        print("check_release: FAIL", file=sys.stderr)
        return 1

    cur = (matrix.get("product") or {}).get("current")
    print(f"check_release: OK (product.current={cur})")
    if not args.skip_repo_pins:
        print(
            f"  gfc_client={read_gfc_client()}  node_agent={read_node_agent()}  api={read_api_version()}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
