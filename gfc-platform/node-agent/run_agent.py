#!/usr/bin/env python3
"""Standalone entrypoint: python run_agent.py --server ..."""
from node_agent.runner import main

if __name__ == "__main__":
    raise SystemExit(main())
