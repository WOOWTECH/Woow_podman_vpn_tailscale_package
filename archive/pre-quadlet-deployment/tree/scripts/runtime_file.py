#!/usr/bin/env python3
"""Validate a temporary file before exposing it as a Podman bind mount."""
import argparse
from pathlib import Path
import stat
import sys


def validate(runtime_value, file_value):
    runtime = Path(runtime_value)
    path = Path(file_value)
    if not runtime.is_absolute() or not path.is_absolute():
        raise ValueError("runtime and temporary file paths must be absolute")
    try:
        runtime_info = runtime.lstat()
        file_info = path.lstat()
        canonical_runtime = runtime.resolve(strict=True)
        canonical_file = path.resolve(strict=True)
    except OSError as error:
        raise ValueError("runtime temporary file is unavailable") from error
    if not stat.S_ISDIR(runtime_info.st_mode) or stat.S_ISLNK(runtime_info.st_mode) or canonical_runtime != runtime:
        raise ValueError("runtime directory must be canonical and must not be a symlink")
    if path.parent != runtime or canonical_file != path:
        raise ValueError("temporary file must be directly under the exact runtime directory")
    if not stat.S_ISREG(file_info.st_mode) or stat.S_ISLNK(file_info.st_mode):
        raise ValueError("runtime temporary file must be a regular file, not a symlink")
    if stat.S_IMODE(file_info.st_mode) != 0o600:
        raise ValueError("runtime temporary file must be mode 600")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime")
    parser.add_argument("file")
    args = parser.parse_args()
    validate(args.runtime, args.file)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"runtime file check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
