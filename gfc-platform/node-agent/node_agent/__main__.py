import sys

from .runner import build_parser, run_loop


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    run_loop(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
