#!/usr/bin/env python3
"""
Tool installation helper for setup.sh. Installs required tools/plugins (e.g. helm-diff)
so setup.sh can call this instead of inline install commands.

Usage:
  install_tools.py helm-diff   # Install helm-diff plugin (with --verify=false)

Exit: 0 if installed or already present, 1 on failure.
"""

from __future__ import annotations

import subprocess
import sys


def helm_diff_installed() -> bool:
    try:
        r = subprocess.run(
            ["helm", "plugin", "list"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return r.returncode == 0 and "diff" in (r.stdout or "")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def install_helm_diff() -> bool:
    if helm_diff_installed():
        return True
    try:
        r = subprocess.run(
            [
                "helm",
                "plugin",
                "install",
                "https://github.com/databus23/helm-diff",
                "--verify=false",
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if r.returncode != 0:
            if r.stderr:
                print(r.stderr, file=sys.stderr)
            return False
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(str(e), file=sys.stderr)
        return False


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: install_tools.py <tool>\n  tool: helm-diff", file=sys.stderr)
        return 2
    tool = sys.argv[1].strip().lower()
    if tool == "helm-diff":
        return 0 if install_helm_diff() else 1
    print(f"Unknown tool: {tool}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
