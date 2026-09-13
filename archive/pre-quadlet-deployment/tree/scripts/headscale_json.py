#!/usr/bin/env python3
"""Narrow Headscale 0.29 JSON handling; never emits enrollment key material."""
import argparse
import datetime
import json
import os
import tempfile
from pathlib import Path


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def atomic(path, value):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix=".secret.", dir=p.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(str(value))
            f.write("\n")
        os.replace(tmp, p)
        p.chmod(0o600)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def rows(data):
    if isinstance(data, list):
        return data
    if not isinstance(data, dict):
        return []
    for key in ("users", "nodes", "pre_auth_keys", "preauthkeys"):
        value = data.get(key)
        if isinstance(value, list):
            return value
    return []


def node_addresses(node):
    value = node.get("ip_addresses", node.get("ipAddresses", node.get("ips", [])))
    if isinstance(value, str):
        return [value]
    return value if isinstance(value, list) else []


def active_reusable(key, now):
    if key.get("reusable") is not True or key.get("expired") is True:
        return False
    expiration = key.get("expiration") or key.get("expires_at") or key.get("expiresAt")
    if not isinstance(expiration, str) or not expiration:
        return True
    try:
        expires = datetime.datetime.fromisoformat(expiration.replace("Z", "+00:00"))
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        raise ValueError("invalid preauth expiration")
    return expires > now


def main():
    p = argparse.ArgumentParser()
    s = p.add_subparsers(dest="cmd", required=True)
    q = s.add_parser("default-user-id"); q.add_argument("json")
    q = s.add_parser("extract-preauth"); q.add_argument("json"); q.add_argument("id_file"); q.add_argument("key_file")
    q = s.add_parser("find-node"); q.add_argument("json"); q.add_argument("hostname"); q.add_argument("--ip")
    q = s.add_parser("assert-node-id-absent"); q.add_argument("json"); q.add_argument("identifier")
    q = s.add_parser("assert-preauth-id-absent"); q.add_argument("json"); q.add_argument("identifier")
    q = s.add_parser("assert-no-active-reusable"); q.add_argument("json")
    q = s.add_parser("assert-no-key"); q.add_argument("file")
    a = p.parse_args()
    if a.cmd == "assert-no-key":
        raw = Path(a.file).read_text(errors="replace").lower()
        if "authkey" in raw or "preauth" in raw or "tskey-" in raw:
            raise ValueError("key-shaped content found")
        return
    data = load(a.json)
    if a.cmd == "default-user-id":
        ids = [x.get("id") for x in rows(data) if x.get("name") == "default" and isinstance(x.get("id"), int)]
        if len(ids) != 1:
            raise ValueError("expected exactly one numeric default user")
        print(ids[0])
    elif a.cmd == "extract-preauth":
        ident, key = data.get("id"), data.get("key")
        if not isinstance(ident, int) or not isinstance(key, str) or not key:
            raise ValueError("invalid preauth response")
        atomic(a.id_file, ident)
        atomic(a.key_file, key)
    elif a.cmd == "find-node":
        found = [x for x in rows(data) if (x.get("given_name") or x.get("name") or x.get("hostname")) == a.hostname]
        if a.ip:
            found = [x for x in found if a.ip in node_addresses(x)]
        if len(found) != 1 or not isinstance(found[0].get("id"), int):
            raise ValueError("expected exactly one gateway node matching hostname and address")
        print(found[0]["id"])
    elif a.cmd == "assert-node-id-absent":
        if any(str(x.get("id")) == a.identifier for x in rows(data)):
            raise ValueError("node identifier remains present")
    elif a.cmd == "assert-preauth-id-absent":
        if any(str(x.get("id")) == a.identifier for x in rows(data)):
            raise ValueError("preauth identifier remains present")
    elif a.cmd == "assert-no-active-reusable":
        now = datetime.datetime.now(datetime.timezone.utc)
        if any(active_reusable(x, now) for x in rows(data)):
            raise ValueError("active reusable preauth key remains")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError, AttributeError) as e:
        raise SystemExit(f"headscale JSON validation failed: {type(e).__name__}")
