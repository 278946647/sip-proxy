import sys

from .runner import build_parser, main as run_main


def main(argv: list[str] | None = None) -> int:
    return run_main(argv)


if __name__ == "__main__":
    sys.exit(main())
