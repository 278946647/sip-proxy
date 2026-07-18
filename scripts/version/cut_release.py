#!/usr/bin/env python3
"""
Cut an immutable product release tag from VERSION_MATRIX.json.

Does NOT force-update tags. Does NOT push unless --push.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "docs" / "releases" / "VERSION_MATRIX.json"
NOTES_DIR = ROOT / "docs" / "releases" / "notes"
CHANGELOG = ROOT / "docs" / "releases" / "CHANGELOG.md"


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=check)


def find_release(matrix: dict, version: str) -> dict | None:
    for row in matrix.get("releases") or []:
        if str(row.get("version")) == version:
            return row
    return None


def ensure_notes(version: str, row: dict) -> Path:
    NOTES_DIR.mkdir(parents=True, exist_ok=True)
    path = NOTES_DIR / f"v{version}.md"
    if path.is_file():
        return path
    comps = row.get("components") or {}
    lines = [
        f"# GFC v{version}",
        "",
        f"- **Tag:** `v{version}`",
        f"- **Status:** {row.get('status')}",
        "",
        "## 组件",
        "",
        "| 组件 | 版本 |",
        "|------|------|",
    ]
    for k, v in comps.items():
        lines.append(f"| {k} | {v} |")
    lines += [
        "",
        "## 摘要",
        "",
        str(row.get("notes") or "(填写发行说明)"),
        "",
        "## 升级",
        "",
        "- 同 Major 内直升（见 VERSION_MATRIX）。",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"created notes skeleton: {path}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--push", action="store_true")
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()
    version = args.version.lstrip("v")
    tag = f"v{version}"

    matrix = json.loads(MATRIX.read_text(encoding="utf-8"))
    row = find_release(matrix, version)
    if not row:
        print(f"ERROR: add releases[] row for {version} in VERSION_MATRIX.json first", file=sys.stderr)
        return 1
    if row.get("status") == "planned":
        print("ERROR: refuse to tag a planned release; set status to current|supported", file=sys.stderr)
        return 1

    cl = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.is_file() else ""
    if f"[{version}]" not in cl:
        print(f"ERROR: CHANGELOG.md missing ## [{version}] section", file=sys.stderr)
        return 1

    st = run(["git", "status", "--porcelain"], check=False)
    if st.stdout.strip() and not args.allow_dirty:
        print("ERROR: working tree not clean. Commit first or pass --allow-dirty.", file=sys.stderr)
        print(st.stdout)
        return 1

    exists = run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], check=False)
    if exists.returncode == 0:
        print(f"ERROR: tag {tag} already exists. Never retag. Cut a new PATCH instead.", file=sys.stderr)
        return 1

    check = run([sys.executable, str(ROOT / "scripts" / "version" / "check_release.py")], check=False)
    print(check.stdout)
    if check.returncode != 0:
        print(check.stderr, file=sys.stderr)
        print("ERROR: check_release failed", file=sys.stderr)
        return 1

    cur = str((matrix.get("product") or {}).get("current") or "")
    if cur != version:
        print(
            f"WARN: product.current={cur} != {version}. Update matrix product.current.",
            file=sys.stderr,
        )

    notes = ensure_notes(version, row)
    msg = f"GFC {tag}\n\nSee docs/releases/notes/v{version}.md and CHANGELOG.md"

    if args.dry_run:
        print(f"DRY-RUN: would create annotated tag {tag}")
        print(f"  notes: {notes}")
        return 0

    st2 = run(["git", "status", "--porcelain", str(notes)], check=False)
    if st2.stdout.strip() and not args.allow_dirty:
        print(f"ERROR: {notes} is new/uncommitted. Commit then re-run.", file=sys.stderr)
        return 1

    run(["git", "tag", "-a", tag, "-m", msg])
    print(f"created annotated tag {tag}")
    if args.push:
        run(["git", "push", "origin", tag])
        print(f"pushed {tag} to origin")
    else:
        print(f"next: git push origin {tag}")
    print("IMPORTANT: do not git tag -f / force-push this tag.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
