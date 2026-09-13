#!/usr/bin/env python3
"""Fail-closed exact ownership checks for gateway Podman resources."""
import argparse
import json
import os
import stat
import subprocess
import sys

PROJECT = "woow-tailscale-gateway"
MANAGED = "woow-gateway-lifecycle"
CONTAINER = "woow-tailscale-gateway"
VOLUME = "woow-tailscale-gateway-state"


def run(args, check=False):
    return subprocess.run(args, text=True, capture_output=True, check=check)


def inspect(kind, name):
    p = run(["podman", kind, "inspect", name])
    if p.returncode:
        if "no such" in p.stderr.lower() or "not found" in p.stderr.lower():
            return None
        raise ValueError(f"podman {kind} inspect failed")
    data = json.loads(p.stdout)
    return data[0] if isinstance(data, list) else data


def labels(obj):
    return obj.get("Labels") or obj.get("Config", {}).get("Labels") or {}


def required(checkout, role):
    return {
        "org.woow-tailscale.project": PROJECT,
        "org.woow-tailscale.role": role,
        "org.woow-tailscale.managed-by": MANAGED,
        "org.woow-tailscale.checkout": checkout,
    }


def check_labels(obj, checkout, role):
    got = labels(obj)
    for key, value in required(checkout, role).items():
        if got.get(key) != value:
            raise ValueError(f"ownership mismatch: {key}")


def check_enrollment_keyfile(path):
    expected = os.path.abspath(path)
    try:
        info = os.lstat(expected)
    except OSError as e:
        raise ValueError("enrollment keyfile is unavailable") from e
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ValueError("enrollment keyfile must be a regular file")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("enrollment keyfile must be mode 600")
    return expected


def is_secret_mount(mount):
    destination = mount.get("Destination") or ""
    return destination == "/run/secrets" or destination.startswith("/run/secrets/")


def check_container(obj, checkout, enrollment_keyfile=None, invocation=None):
    name = (obj.get("Name") or obj.get("Names") or "").lstrip("/")
    if name != CONTAINER:
        raise ValueError("container exact-name mismatch")
    check_labels(obj, checkout, "gateway")
    mounts = obj.get("Mounts", [])
    expected = [m for m in mounts if m.get("Destination") == "/var/lib/tailscale"]
    state_mounts = [m for m in mounts if m.get("Name") == VOLUME]
    if len(expected) != 1 or expected[0].get("Name") != VOLUME or len(state_mounts) != 1:
        raise ValueError("state mount mismatch")
    if enrollment_keyfile is None:
        if any(is_secret_mount(m) for m in mounts):
            raise ValueError("secret mount present")
        return

    keyfile = check_enrollment_keyfile(enrollment_keyfile)
    if labels(obj).get("org.woow-tailscale.invocation") != invocation:
        raise ValueError("enrollment invocation mismatch")
    secret_mounts = [
        m for m in mounts
        if is_secret_mount(m) or m.get("Source") == keyfile
    ]
    if len(secret_mounts) != 1:
        raise ValueError("enrollment secret mount count mismatch")
    secret = secret_mounts[0]
    if (
        secret.get("Type") != "bind"
        or secret.get("Source") != keyfile
        or secret.get("Destination") != "/run/secrets/headscale-preauth.key"
        or secret.get("RW") is not False
    ):
        raise ValueError("enrollment secret mount mismatch")


def check_volume(obj, checkout):
    if obj.get("Name") != VOLUME:
        raise ValueError("volume exact-name mismatch")
    check_labels(obj, checkout, "state")


def reconcile_container(checkout):
    obj = inspect("container", CONTAINER)
    if obj is None:
        return
    check_container(obj, checkout)
    if obj.get("State", {}).get("Running") is True:
        raise ValueError("refusing to remove active gateway container")
    removed = run(["podman", "container", "rm", CONTAINER])
    if removed.returncode:
        raise ValueError("failed to remove stale owned gateway container")
    if inspect("container", CONTAINER) is not None:
        raise ValueError("stale gateway container remains after removal")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("command", choices=("check-container", "check-volume", "assert-container-absent", "assert-volume-absent", "reconcile-container", "snapshot"))
    p.add_argument("checkout")
    p.add_argument("--allow-absent", action="store_true")
    p.add_argument("--enrollment-keyfile")
    p.add_argument("--invocation")
    a = p.parse_args()
    enrollment = a.enrollment_keyfile is not None or a.invocation is not None
    if enrollment and (a.enrollment_keyfile is None or not a.invocation):
        raise ValueError("enrollment keyfile and invocation must be provided together")
    if enrollment and a.command != "check-container":
        raise ValueError("enrollment mode is only valid for check-container")
    if a.command == "snapshot":
        q = run(["podman", "container", "inspect", "--all"], check=True)
        print(q.stdout, end="")
        return
    if a.command == "reconcile-container":
        reconcile_container(a.checkout)
        return
    kind = "container" if "container" in a.command else "volume"
    name = CONTAINER if kind == "container" else VOLUME
    obj = inspect(kind, name)
    if a.command.startswith("assert-"):
        if obj is not None:
            raise ValueError(f"{kind} remains present")
        return
    if obj is None:
        if a.allow_absent:
            return
        raise ValueError(f"required {kind} is absent")
    if kind == "container":
        check_container(obj, a.checkout, a.enrollment_keyfile, a.invocation)
    else:
        check_volume(obj, a.checkout)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as e:
        print(f"ownership check failed: {e}", file=sys.stderr)
        raise SystemExit(1)
