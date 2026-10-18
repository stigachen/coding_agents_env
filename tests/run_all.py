#!/usr/bin/env python3
"""Run every agent unittest suite.

Discovering the whole repository in one interpreter collides on test_install.py.
Each directory is a separate process instead.
"""

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    ROOT / "claude" / "tests",
    ROOT / "codex" / "tests",
    ROOT / "grok" / "tests",
    ROOT / "opencode" / "tests",
    ROOT / "tests",
)


def main() -> int:
    failed = []
    for start in SUITES:
        if not start.is_dir():
            continue
        print("== " + start.relative_to(ROOT).as_posix(), flush=True)
        result = subprocess.run(
            [sys.executable, "-m", "unittest", "discover", "-s", str(start), "-v"],
            cwd=str(ROOT),
        )
        if result.returncode != 0:
            failed.append(start.relative_to(ROOT).as_posix())
    if failed:
        print("failed: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
