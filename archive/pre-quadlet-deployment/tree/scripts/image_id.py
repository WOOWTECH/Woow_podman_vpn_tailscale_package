#!/usr/bin/env python3
"""Normalize a Podman image ID without accepting shortened or named references."""
import re
import sys

IMAGE_ID = re.compile(r"(?:sha256:)?([0-9a-f]{64})")


def normalize_image_id(value: str) -> str:
    match = IMAGE_ID.fullmatch(value)
    if not match:
        raise ValueError("image ID must be exactly 64 lowercase hex characters with an optional sha256: prefix")
    return match.group(1)


def main() -> None:
    if len(sys.argv) != 2:
        raise ValueError("exactly one image ID is required")
    print(normalize_image_id(sys.argv[1]))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"invalid image ID: {error}", file=sys.stderr)
        raise SystemExit(1)
