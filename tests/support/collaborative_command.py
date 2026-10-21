"""External command controller for installs and captured verification commands."""
import argparse
import os
from pathlib import Path
import sys

from collaborative_process import CommandFailure, ExpectedExit, run_case


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", type=Path, required=True)
    parser.add_argument("--receipts", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=900)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    environment = dict(os.environ)
    environment["GAUNTLET_TEST_RECEIPTS"] = str(arguments.receipts.resolve())
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        result = run_case(command, cwd=arguments.cwd.resolve(), environment=environment,
                          deadline_seconds=arguments.seconds, expected=ExpectedExit())
    except CommandFailure as error:
        result = error.outcome
    sys.stdout.buffer.write(result.stdout.prefix)
    sys.stderr.buffer.write(result.stderr.prefix)
    print(f"\nreceipt={result.receipt_path}; completed={result.completed}; "
          f"exit={result.exit_code}; retired={result.tree_retired}", file=sys.stderr)
    return 0 if result.completed else 1


if __name__ == "__main__":
    raise SystemExit(main())
