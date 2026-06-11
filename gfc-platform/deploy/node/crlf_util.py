"""CRLF helpers for forward-node deploy (safe for .py and .sh)."""
from __future__ import annotations

import re
from pathlib import Path

# Never write the merged token as one literal in this module (Windows CRLF fix must not corrupt .py).
_PIPEFAIL_MERGED = "pipefail" + "STATE="

_SKIP_CRLF = frozenset(
    {
        Path(__file__).resolve().name,
        "_repair_impl.py",
        "repair_forward_node.py",
    }
)

_CORRUPT_BLOCK = re.compile(
    r"        text = p\.read_bytes\(\).*?        if fixed != text:",
    re.DOTALL,
)

_GOOD_BLOCK = (
    "        text = p.read_bytes().decode(\"utf-8\", errors=\"replace\")\n"
    "        fixed = text.replace(\"\\r\\n\", \"\\n\").replace(\"\\r\", \"\\n\")\n"
    "        if p.suffix == \".sh\":\n"
    f"            fixed = fixed.replace(\"{_PIPEFAIL_MERGED}\", \"pipefail\\nSTATE=\")\n"
    "        if fixed != text:"
)


def fix_text(path: Path, text: str) -> str:
    fixed = text.replace("\r\n", "\n").replace("\r", "\n")
    if path.suffix == ".sh":
        fixed = fixed.replace(_PIPEFAIL_MERGED, "pipefail\nSTATE=")
    return fixed


def fix_file(path: Path, *, skip_names: frozenset[str] | None = None) -> bool:
    skip = _SKIP_CRLF if skip_names is None else skip_names
    if path.name in skip:
        return False
    text = path.read_bytes().decode("utf-8", errors="replace")
    fixed = fix_text(path, text)
    if fixed == text:
        return False
    path.write_text(fixed, encoding="utf-8", newline="\n")
    return True


def fix_tree(root: Path) -> int:
    names = {"gfc.env", "node.env"}
    suffixes = {".sh", ".py", ".nft", ".env"}
    n = 0
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if p.name in _SKIP_CRLF:
            continue
        if p.suffix not in suffixes and p.name not in names:
            continue
        if fix_file(p):
            print(f"  fixed CRLF: {p}")
            n += 1
    return n


def patch_corrupted_python(root: Path) -> int:
    """Repair .py files broken by an old CRLF pass that split pipefail string literals."""
    n = 0
    for p in root.rglob("*.py"):
        raw = p.read_bytes().decode("utf-8", errors="replace")
        if "if p.suffix == \".sh\":" in raw and _PIPEFAIL_MERGED not in raw:
            if 'fixed = fixed.replace("pipefail\n' not in raw:
                continue
        if not _CORRUPT_BLOCK.search(raw):
            continue
        new = _CORRUPT_BLOCK.sub(_GOOD_BLOCK, raw, count=1)
        if new == raw:
            continue
        p.write_text(new, encoding="utf-8", newline="\n")
        print(f"  patched corrupt Python: {p}")
        n += 1
    return n
