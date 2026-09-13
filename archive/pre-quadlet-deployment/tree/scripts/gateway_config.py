#!/usr/bin/env python3
"""Strict, non-shell gateway configuration parser and renderer."""
import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

REQUIRED = {"GATEWAY_HOSTNAME", "HEADSCALE_URL", "HEADSCALE_CONTAINER", "HEADSCALE_USER", "STATE_VOLUME"}
FIXED_INPUT = {
    "HEADSCALE_CONTAINER": "headscale",
    "HEADSCALE_USER": "default",
    "STATE_VOLUME": "woow-tailscale-gateway-state",
}
FIXED_RUNTIME = {
    "TS_GATEWAY_MODE": "true", "TS_USERSPACE_NETWORKING": "true", "TS_WEB_UI": "false",
    "TS_ACCEPT_DNS": "true", "TS_ALWAYS_USE_DERP": "false", "TS_ADVERTISE_CONNECTOR": "false",
    "TS_WEB_LISTEN": "127.0.0.1:8088", "TS_SERVE_TCP_18081": "127.0.0.1:18081",
    "TS_SERVE_TCP_18069": "127.0.0.1:18069",
}
HOST_RE = re.compile(r"(?=^.{1,253}$)(?!-)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.(?!-)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$")


def parse(path):
    raw = Path(path).read_bytes()
    if b"\x00" in raw or b"\r" in raw:
        raise ValueError("configuration contains forbidden control characters")
    try: text = raw.decode("utf-8")
    except UnicodeDecodeError as e: raise ValueError("configuration is not UTF-8") from e
    out = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line or line.startswith("#"): continue
        if any(ord(c) < 32 for c in line): raise ValueError(f"line {number}: control character")
        if line != line.strip() or "=" not in line: raise ValueError(f"line {number}: expected literal KEY=VALUE")
        key, value = line.split("=", 1)
        if key not in REQUIRED: raise ValueError(f"line {number}: unknown key {key!r}")
        if key in out: raise ValueError(f"line {number}: duplicate key {key!r}")
        if not value: raise ValueError(f"line {number}: blank value")
        if any(x in value for x in ("$", "`", "\\", "'", '"', ";")):
            raise ValueError(f"line {number}: shell syntax is forbidden")
        out[key] = value
    missing = REQUIRED - out.keys()
    if missing: raise ValueError("missing keys: " + ", ".join(sorted(missing)))
    if not HOST_RE.fullmatch(out["GATEWAY_HOSTNAME"]): raise ValueError("invalid gateway DNS hostname")
    for key, expected in FIXED_INPUT.items():
        if out[key] != expected: raise ValueError(f"{key} must be exactly {expected}")
    url = urlsplit(out["HEADSCALE_URL"])
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError("HEADSCALE_URL must be an HTTP(S) URL without credentials, query, or fragment")
    if url.path not in ("", "/"): raise ValueError("HEADSCALE_URL must not contain a path")
    host = url.hostname
    if ":" in host: host = f"[{host}]"
    if url.port: host += f":{url.port}"
    out["HEADSCALE_URL"] = urlunsplit((url.scheme, host, "", "", ""))
    return out


def runtime(config):
    return {"TS_HOSTNAME": config["GATEWAY_HOSTNAME"], "TS_LOGIN_SERVER": config["HEADSCALE_URL"], **FIXED_RUNTIME}


def atomic_write(path, data):
    path = Path(path); os.umask(0o077); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700); path.parent.chmod(0o700)
    fd, temp = tempfile.mkstemp(prefix=".gateway.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(temp, path); path.chmod(0o600)
    finally:
        try: os.unlink(temp)
        except FileNotFoundError: pass


def main():
    p = argparse.ArgumentParser(); sub = p.add_subparsers(dest="cmd", required=True)
    q = sub.add_parser("parse-env"); q.add_argument("input")
    q = sub.add_parser("render"); q.add_argument("input"); q.add_argument("output", nargs="?", default="runtime/gateway.env")
    a = p.parse_args(); conf = parse(a.input)
    if a.cmd == "parse-env": print(json.dumps(conf, sort_keys=True))
    else:
        values = runtime(conf)
        atomic_write(a.output, "".join(f"{k}={v}\n" for k, v in values.items()))

if __name__ == "__main__":
    try: main()
    except (OSError, ValueError) as e: raise SystemExit(f"gateway configuration error: {e}")
