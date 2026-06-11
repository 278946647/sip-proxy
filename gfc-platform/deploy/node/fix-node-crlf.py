#!/usr/bin/env python3
"""修复 deploy/node 下脚本的 Windows CRLF（从 Windows 拷贝后先跑本脚本）。

用法:
  sudo python3 /var/socks/deploy/node/fix-node-crlf.py
  sudo python3 fix-node-crlf.py /var/socks
"""
from __future__ import annotations

import sys
from pathlib import Path

_DIR = Path(__file__).resolve().parent
if str(_DIR) not in sys.path:
    sys.path.insert(0, str(_DIR))

from crlf_util import fix_tree, patch_corrupted_python  # noqa: E402


def main() -> int:
    if len(sys.argv) > 1:
        root = Path(sys.argv[1])
        node_dir = root / "deploy/node" if (root / "deploy/node").is_dir() else root
    else:
        node_dir = _DIR
        root = node_dir.parent.parent

    print(f"==> 修复 CRLF: {node_dir}")
    n = fix_tree(node_dir)
    p = patch_corrupted_python(node_dir)
    print(f"==> 完成: {n} 个文件已修复 CRLF, {p} 个 Python 已修补")
    if n or p:
        print("    现在可执行: sudo bash deploy/node/install.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
