#!/usr/bin/env python3
"""Scan repository/runtime bytes for credential shapes without echoing matches."""
import argparse
import os
import re
import sys
from pathlib import Path

# Split literals keep the scanner's own source from resembling a credential.
KEY = re.compile(
    b"(?:tskey-(?:auth|client|node)|hskey-auth)-[A-Za-z0-9_-]{12,}|"
    + b"-----BEGIN " + b"(?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    re.IGNORECASE,
)
LIVE = re.compile(
    b"(?:--authkey=|TS_AUTHKEY=|HEADSCALE_PREAUTH_KEY=)"
    + b"(?!<redacted>)(?![\"']?\$)(?![\"']?(?:$|[\r\n]))[^\s]+",
    re.IGNORECASE,
)


def unsafe(path: Path, runtime_evidence: bool = False) -> bool:
    try:
        data = path.read_bytes()
    except (OSError, ValueError):
        return True
    return bool(KEY.search(data) or (runtime_evidence and LIVE.search(data)))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--runtime-evidence", action="append", default=[], type=Path)
    args = parser.parse_args()
    bad = False
    for base, dirs, files in os.walk(args.root):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            path = Path(base) / name
            if unsafe(path, runtime_evidence="runtime" in path.relative_to(args.root).parts):
                bad = True
    for path in args.runtime_evidence:
        if unsafe(path, runtime_evidence=True):
            bad = True
    if bad:
        print("credential-shaped content detected", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
