#!/usr/bin/env python3
"""Fail-closed cleanup for resources owned by one live-test invocation."""
import argparse
import json
import subprocess
import sys
import time

PROJECT = "woow-tailscale-gateway"
MANAGED = "woow-gateway-lifecycle"
ROLE = "live-test"
NETWORK_REMOVE_ATTEMPTS = 5
NETWORK_RETRY_DELAY_SECONDS = 1


def command(args):
    return subprocess.run(args, text=True, capture_output=True)


def absent_inspect_error(kind, stderr):
    error = stderr.strip().lower()
    if "no such" in error or "not found" in error:
        return True
    # Podman 4.9 can omit "not found" and report this form for an absent
    # network. Keep it resource-specific so unrelated lookup failures fail shut.
    return error.startswith(f"error: unable to find {kind} ") or error.startswith(f"unable to find {kind} ")


class ForeignResourceError(ValueError):
    pass


class ResourceInspectError(ValueError):
    pass


def inspect_owned(kind, name, invocation):
    result = command(["podman", kind, "inspect", name])
    if result.returncode:
        if absent_inspect_error(kind, result.stderr):
            return None
        raise ResourceInspectError(f"{kind} inspection failed")
    data = json.loads(result.stdout)
    obj = data[0] if isinstance(data, list) else data
    labels = obj.get("Labels") or obj.get("Config", {}).get("Labels")
    if not labels and kind == "network":
        labels = obj.get("labels")
    labels = labels or {}
    expected = {
        "org.woow-tailscale.project": PROJECT,
        "org.woow-tailscale.role": ROLE,
        "org.woow-tailscale.managed-by": MANAGED,
        "org.woow-tailscale.invocation": invocation,
    }
    if any(labels.get(key) != value for key, value in expected.items()):
        raise ForeignResourceError(f"refusing foreign same-name {kind}")
    return obj


def transient_network_in_use_error(stderr):
    error = stderr.strip().lower()
    return "network" in error and (
        "is being used" in error
        or "is in use" in error
        or " has associated containers" in error
    )


def remove_owned_network(name, invocation, errors, description):
    for attempt in range(NETWORK_REMOVE_ATTEMPTS):
        try:
            obj = inspect_owned("network", name, invocation)
        except ForeignResourceError:
            errors.append(f"{description} is foreign; refusing removal")
            return
        except (ResourceInspectError, json.JSONDecodeError):
            errors.append(f"{description} inspection failed; absence cannot be verified")
            return
        if obj is None:
            return

        # Revalidate exact invocation ownership before every force attempt. A
        # same-name foreign replacement is never removed or retried.
        result = command(["podman", "network", "rm", "-f", name])
        transient_in_use = result.returncode and transient_network_in_use_error(result.stderr)
        try:
            remains = inspect_owned("network", name, invocation)
        except ForeignResourceError:
            errors.append(f"{description} is foreign; refusing further removal")
            return
        except (ResourceInspectError, json.JSONDecodeError):
            errors.append(f"{description} inspection failed; absence cannot be verified")
            return
        if remains is None:
            return
        if result.returncode and not transient_in_use:
            errors.append(f"{description} removal failed")
            return
        if attempt + 1 == NETWORK_REMOVE_ATTEMPTS:
            if transient_in_use:
                errors.append(f"{description} remained in use after bounded removal retries")
            else:
                errors.append(f"{description} remains after bounded removal retries")
            return
        time.sleep(NETWORK_RETRY_DELAY_SECONDS)


def remove_owned(kind, name, invocation, errors, description):
    if kind == "network":
        remove_owned_network(name, invocation, errors, description)
        return
    try:
        obj = inspect_owned(kind, name, invocation)
        if obj is not None:
            if kind == "container":
                args = ["podman", "rm", "-f", name]
            else:
                args = ["podman", kind, "rm", name]
            result = command(args)
            if result.returncode:
                errors.append(f"{description} removal failed")
        if inspect_owned(kind, name, invocation) is not None:
            errors.append(f"{description} remains")
    except (ValueError, json.JSONDecodeError):
        errors.append(f"{description} is foreign or absence cannot be verified")


def rows(data, names):
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for name in names:
            if isinstance(data.get(name), list):
                return data[name]
    return []


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--headscale", required=True)
    p.add_argument("--invocation", required=True)
    p.add_argument("--container", default="")
    p.add_argument("--container-created", action="store_true")
    p.add_argument("--volume", default="")
    p.add_argument("--volume-created", action="store_true")
    p.add_argument("--network", default="")
    p.add_argument("--network-created", action="store_true")
    p.add_argument("--probe", action="append", default=[])
    p.add_argument("--key-id", default="")
    p.add_argument("--key-required", action="store_true")
    p.add_argument("--node-id", default="")
    p.add_argument("--baseline-node-id", action="append", default=[])
    p.add_argument("--node-hostname", default="")
    p.add_argument("--node-ip", default="")
    a = p.parse_args()
    errors = []

    for probe in a.probe:
        remove_owned("container", probe, a.invocation, errors, "HTTP probe container")
    if a.container_created:
        remove_owned("container", a.container, a.invocation, errors, "test container")

    if a.key_required and not a.key_id:
        errors.append("test enrollment key identifier unavailable; absence cannot be verified")
    if a.key_id:
        command(["podman", "exec", a.headscale, "headscale", "preauthkeys", "expire", "--id", a.key_id])
        command(["podman", "exec", a.headscale, "headscale", "preauthkeys", "delete", "--id", a.key_id])
        result = command(["podman", "exec", a.headscale, "headscale", "preauthkeys", "list", "--output", "json"])
        try:
            keys = rows(json.loads(result.stdout), ("pre_auth_keys", "preauthkeys")) if result.returncode == 0 else []
        except json.JSONDecodeError:
            keys = []
            result = type("Result", (), {"returncode": 1})()
        if result.returncode or any(str(item.get("id")) == a.key_id for item in keys):
            errors.append("test enrollment key remains or cannot be verified absent")

    baseline_node_ids = set(a.baseline_node_id)
    node_ids = {a.node_id} if a.node_id else set()
    initial = command(["podman", "exec", a.headscale, "headscale", "nodes", "list", "--output", "json"]) if a.headscale else None
    if initial and initial.returncode == 0 and a.node_hostname:
        try:
            for item in rows(json.loads(initial.stdout), ("nodes",)):
                hostname = item.get("given_name") or item.get("name") or item.get("hostname")
                addresses = item.get("ip_addresses", item.get("ipAddresses", item.get("ips", [])))
                if isinstance(addresses, str):
                    addresses = [addresses]
                identifier = str(item.get("id"))
                if identifier not in baseline_node_ids and hostname == a.node_hostname and (not a.node_ip or a.node_ip in addresses):
                    node_ids.add(identifier)
        except json.JSONDecodeError:
            errors.append("test Headscale node could not be enumerated")
    for node_id in node_ids - {"", "None"}:
        command(["podman", "exec", a.headscale, "headscale", "--force", "nodes", "delete", "--identifier", node_id])
    if a.node_id or a.node_hostname:
        result = command(["podman", "exec", a.headscale, "headscale", "nodes", "list", "--output", "json"])
        try:
            nodes = rows(json.loads(result.stdout), ("nodes",)) if result.returncode == 0 else []
        except json.JSONDecodeError:
            nodes = []
            result = type("Result", (), {"returncode": 1})()
        remains = []
        for item in nodes:
            hostname = item.get("given_name") or item.get("name") or item.get("hostname")
            addresses = item.get("ip_addresses", item.get("ipAddresses", item.get("ips", [])))
            if isinstance(addresses, str):
                addresses = [addresses]
            identifier = str(item.get("id"))
            if identifier not in baseline_node_ids and (identifier == a.node_id or (hostname == a.node_hostname and (not a.node_ip or a.node_ip in addresses))):
                remains.append(item)
        if result.returncode or remains:
            errors.append("test Headscale node remains or cannot be verified absent")

    if a.volume_created:
        remove_owned("volume", a.volume, a.invocation, errors, "test volume")
    if a.network_created:
        remove_owned("network", a.network, a.invocation, errors, "test network")

    if errors:
        print("live-test cleanup failed: " + "; ".join(dict.fromkeys(errors)), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
