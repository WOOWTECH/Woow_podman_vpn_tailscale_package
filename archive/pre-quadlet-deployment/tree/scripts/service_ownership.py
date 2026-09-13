#!/usr/bin/env python3
"""Fail closed unless the live NPM and Odoo stacks belong to their approved checkouts."""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

NPM_IMAGE = "docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb"
ODOO_IMAGE = "docker.io/library/odoo:18.0@sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67"
COMPOSE_LABELS = {
    "project": "com.docker.compose.project",
    "working_dir": "com.docker.compose.project.working_dir",
    "config_files": "com.docker.compose.project.config_files",
    "service": "com.docker.compose.service",
}


@dataclass(frozen=True)
class Service:
    unit: str
    checkout_name: str
    template: str
    placeholder: str
    container: str
    project: str
    compose_service: str
    image: str
    owner_labels: dict
    ports: dict
    mounts: tuple


def services():
    home = Path.home()
    npm = home / "Woow_podman_nginxpm"
    owner = npm_owner(npm)
    return (
        Service(
            "nginx-proxy-manager.service", "Woow_podman_nginxpm",
            "systemd/nginx-proxy-manager.service", "@REPO_ROOT@", "npm-app",
            "nginxpm", "app", NPM_IMAGE,
            {"io.woow.nginxpm.managed": "true", "io.woow.nginxpm.owner": owner},
            {"80/tcp": (("0.0.0.0", "80"),), "443/tcp": (("0.0.0.0", "443"),),
             "81/tcp": (("127.0.0.1", "18081"),)},
            (("volume", "npm-app-data", "/data", True),
             ("volume", "npm-letsencrypt", "/etc/letsencrypt", True)),
        ),
        Service(
            "odoo18.service", "Woow_podman_odoo", "systemd/odoo18.service.in",
            "@PROJECT_ROOT@", "odoo18-web", "odoo18", "web", ODOO_IMAGE,
            {"io.woowtech.stack": "odoo18", "io.woowtech.owner": str(os.getuid())},
            {"8069/tcp": (("127.0.0.1", "18069"),)},
            (("volume", "odoo18-web-data", "/var/lib/odoo", True),
             ("bind", str(home / "Woow_podman_odoo/addons"), "/mnt/extra-addons", False),
             ("bind", str(home / "Woow_podman_odoo/.runtime/config/odoo.conf"), "/etc/odoo/odoo.conf", False),
             ("bind", str(home / "Woow_podman_odoo/scripts/odoo-healthcheck.py"), "/usr/local/bin/odoo-healthcheck", False)),
        ),
    )


def output(args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise ValueError("command failed: " + " ".join(args[:3]))
    return result.stdout.strip()


def inspect(kind, name):
    data = json.loads(output(["podman", kind, "inspect", name]))
    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], dict):
        raise ValueError(f"ambiguous {kind} inspect result: {name}")
    return data[0]


def succeeds(args):
    return subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def safe_checkout(name):
    checkout = Path.home() / name
    try:
        info = checkout.lstat()
    except OSError as exc:
        raise ValueError(f"approved checkout is unavailable: {checkout}") from exc
    if not stat.S_ISDIR(info.st_mode) or checkout.is_symlink() or checkout.resolve() != checkout or info.st_uid != os.getuid():
        raise ValueError(f"foreign or non-canonical checkout: {checkout}")
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise ValueError(f"checkout is group/world writable: {checkout}")
    return checkout


def safe_file(path, description, mode=None):
    try:
        info = path.lstat()
    except OSError as exc:
        raise ValueError(f"missing {description}: {path}") from exc
    if not stat.S_ISREG(info.st_mode) or path.is_symlink() or info.st_uid != os.getuid():
        raise ValueError(f"foreign or unsafe {description}: {path}")
    permissions = stat.S_IMODE(info.st_mode)
    if permissions & 0o022 or (mode is not None and permissions != mode):
        raise ValueError(f"unsafe mode for {description}: {path}")
    return path.read_text()


def npm_owner(checkout):
    safe_checkout("Woow_podman_nginxpm")
    owner_file = checkout / ".state/owner-id"
    checkout_file = checkout / ".state/checkout"
    owner = safe_file(owner_file, "NPM owner state", 0o600).strip()
    recorded_checkout = safe_file(checkout_file, "NPM checkout state", 0o600).rstrip("\n")
    expected = hashlib.sha256(f"woow-nginxpm-owner-v1:{checkout}".encode()).hexdigest()
    if owner != expected or recorded_checkout != str(checkout):
        raise ValueError("NPM checkout ownership state mismatch")
    return owner


def render_template(service, checkout):
    template = checkout / service.template
    text = safe_file(template, f"{service.unit} repository template")
    if text.count(service.placeholder) == 0:
        raise ValueError(f"unit template placeholder is absent: {service.unit}")
    replacement = str(checkout)
    if service.unit == "nginx-proxy-manager.service":
        replacement = replacement.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    return text.replace(service.placeholder, replacement)


def check_unit(service, checkout):
    canonical = Path.home() / ".config/systemd/user" / service.unit
    fragment_text = safe_file(canonical, f"installed {service.unit}")
    fragment_value = output(["systemctl", "--user", "show", "-p", "FragmentPath", "--value", service.unit])
    if not fragment_value:
        raise ValueError(f"service unit has no fragment path: {service.unit}")
    fragment = Path(fragment_value)
    if fragment != canonical or fragment.resolve() != canonical:
        raise ValueError(f"non-canonical service unit: {service.unit}")
    if fragment_text != render_template(service, checkout):
        raise ValueError(f"installed unit differs from repository template: {service.unit}")
    if not succeeds(["systemctl", "--user", "is-active", "--quiet", service.unit]):
        raise ValueError(f"service unit is not active: {service.unit}")


def normalized_image_id(value):
    if not isinstance(value, str):
        raise ValueError("image identity is absent")
    raw = value.removeprefix("sha256:")
    if len(raw) != 64 or any(ch not in "0123456789abcdef" for ch in raw):
        raise ValueError("image identity is not a full sha256")
    return raw


def normalized_immutable_reference(value):
    """Return the exact repository and digest, omitting an optional display tag."""
    if not isinstance(value, str) or value.count("@") != 1:
        raise ValueError("image reference is not unambiguously digest-pinned")
    name, digest = value.split("@")
    if not digest.startswith("sha256:"):
        raise ValueError("image reference digest is not a sha256")
    digest = normalized_image_id(digest)

    slash = name.rfind("/")
    colon = name.rfind(":")
    repository = name
    if colon > slash:
        tag = name[colon + 1:]
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
            raise ValueError("image reference tag is invalid")
        repository = name[:colon]
    if (not repository or repository != repository.lower()
            or any(ch.isspace() for ch in repository)):
        raise ValueError("image reference repository is not normalized")
    return repository, digest


def expected_labels(service, checkout):
    return {
        **service.owner_labels,
        COMPOSE_LABELS["project"]: service.project,
        COMPOSE_LABELS["working_dir"]: str(checkout),
        COMPOSE_LABELS["config_files"]: str(checkout / "docker-compose.yml"),
        COMPOSE_LABELS["service"]: service.compose_service,
    }


def normalized_bindings(bindings):
    if not isinstance(bindings, dict):
        raise ValueError("container port bindings are absent")
    normalized = {}
    for port, entries in bindings.items():
        if not isinstance(entries, list):
            raise ValueError("container port binding list is invalid")
        values = []
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"HostIp", "HostPort"}:
                raise ValueError("container port binding is not exact")
            host_ip = entry["HostIp"]
            # Podman 4.9 reports an IPv4 wildcard either as an empty string or
            # 0.0.0.0. No other address receives this normalization.
            if host_ip == "":
                host_ip = "0.0.0.0"
            values.append((host_ip, entry["HostPort"]))
        normalized[port] = tuple(values)
    return normalized


def check_mounts(service, obj):
    actual = obj.get("Mounts")
    if not isinstance(actual, list) or len(actual) != len(service.mounts):
        raise ValueError(f"container mount count mismatch: {service.container}")
    unmatched = list(actual)
    for kind, source, destination, read_write in service.mounts:
        matches = []
        for mount in unmatched:
            actual_source = mount.get("Name") if kind == "volume" else mount.get("Source")
            if (mount.get("Type") == kind and actual_source == source
                    and mount.get("Destination") == destination and mount.get("RW") is read_write):
                matches.append(mount)
        if len(matches) != 1:
            raise ValueError(f"container exact mount mismatch: {service.container}")
        unmatched.remove(matches[0])


def check_container(service, checkout):
    obj = inspect("container", service.container)
    if (obj.get("Name") or "").lstrip("/") != service.container or obj.get("State", {}).get("Running") is not True:
        raise ValueError(f"container identity/state mismatch: {service.container}")
    labels = obj.get("Config", {}).get("Labels") or obj.get("Labels") or {}
    required = expected_labels(service, checkout)
    if any(labels.get(key) != value for key, value in required.items()):
        raise ValueError(f"container ownership/compose labels mismatch: {service.container}")
    image = inspect("image", service.image)
    expected_id = image.get("Id") or image.get("ID")
    if normalized_image_id(obj.get("Image")) != normalized_image_id(expected_id):
        raise ValueError(f"container immutable image identity mismatch: {service.container}")
    expected_reference = normalized_immutable_reference(service.image)
    config_image = normalized_immutable_reference(obj.get("Config", {}).get("Image"))
    image_name = normalized_immutable_reference(obj.get("ImageName"))
    if config_image != expected_reference or image_name != expected_reference:
        raise ValueError(f"container immutable image reference mismatch: {service.container}")
    bindings = obj.get("HostConfig", {}).get("PortBindings")
    if normalized_bindings(bindings) != service.ports:
        raise ValueError(f"container exact port binding mismatch: {service.container}")
    check_mounts(service, obj)


def main():
    for service in services():
        checkout = safe_checkout(service.checkout_name)
        safe_file(checkout / "docker-compose.yml", f"{service.project} Compose contract")
        check_unit(service, checkout)
        check_container(service, checkout)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"service ownership check failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
