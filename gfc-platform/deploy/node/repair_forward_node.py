#!/usr/bin/env python3
"""转发节点一键修复（不依赖 bash，避免 Windows CRLF 破坏脚本）。

在转发节点上执行:
  sudo python3 /var/socks/deploy/node/repair_forward_node.py

若本文件报 SyntaxError，可直接执行:
  sudo python3 /var/socks/deploy/node/_repair_impl.py
"""
from __future__ import annotations

import runpy
import sys
from pathlib import Path

_IMPL = Path(__file__).resolve().parent / "_repair_impl.py"


def main() -> int:
    if not _IMPL.is_file():
        print(f"缺少 {_IMPL}，请同步整个 deploy/node/ 目录到服务器")
        return 1
    result = runpy.run_path(str(_IMPL), run_name="__main__")
    if isinstance(result, dict) and "return" in result and result["return"] is not None:
        return int(result["return"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
