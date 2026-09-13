# Woow Tailscale on rootless Podman (Quadlet)

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![Tailscale](https://img.shields.io/badge/tailscale-1.102.3-brightgreen)](https://tailscale.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

A [Tailscale](https://tailscale.com/) node — official control plane or self-hosted
[Headscale](https://headscale.net/) — packaged as a **Quadlet + systemd** deployment for
**rootless Podman**. The unit runs in the host network namespace with userspace
networking, supervised by the user's systemd with `Restart=always` and lingering, so the
node comes back after a crash and after a reboot.

> **This node is very likely a management path into its host.** Tailnet SSH to the node's
> address lands on the host's `127.0.0.1:22`. Every change here — install, upgrade,
> migration — can drop the session you are running it from. Use `--watchdog`, and drive
> the change over a *different* path (a Cloudflare tunnel, the console, the LAN).

> **Docker / compose users:** this repository is Quadlet-only from this version on. The
> last commit with `compose.yml`, the Caddy sidecar and the bridge-network units is tagged
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package/tree/compose-final):
> `git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package.git`.
> It is not maintained, and it did not survive a reboot under Podman.

---

## What you get

| | |
|---|---|
| **Container** | `woow-tailscale` from `localhost/woow-tailscale:1.102.3-r1`, built on this host from `docker.io/tailscale/tailscale:v1.102.3` (pinned) plus this repo's entrypoint |
| **Network** | `Network=host` with `--tun=userspace-networking`: no capabilities, no `/dev/net/tun` |
| **Identity** | a bind-mounted state directory — machine key, node key, prefs and the `tailscale serve` configuration |
| **Settings** | two files under `~/.config/woow-tailscale/`, mode 0600; env names mirror the HA add-on's option keys |
| **Supervision** | `systemd --user` units generated from Quadlet: `Restart=always`, health check `tailscale status --peers=false` |
| **Scripts** | install, upgrade (watchdog + rollback), backup, restore, uninstall, and a migration from a compose/manual deployment |

The image is built locally and lives in no registry, so the unit carries `Pull=never`.
Publishing it to GHCR (so a fresh host can skip the build) is future work.

---

## Why host network + userspace

Rootless Podman cannot grant `NET_ADMIN` over the host's network namespace, so a
kernel-mode `tun` here only crash-loops. In userspace mode tailscaled needs no
capabilities and no device, and everything that matters still works:

- inbound tailnet connections to this node land on host loopback — SSH to the tailnet IP
  reaches `127.0.0.1:22`;
- `tailscale serve` TCP forwards (kept in the state directory) reach `127.0.0.1:<port>`;
- subnet routes and exit-node still work, through the netstack, at some cost in throughput.

This is the primary and only supported path. The removed compose design used a bridge
network, kernel mode and a Caddy sidecar for Basic auth; it needed capabilities it could
not get, and the sidecar received the whole env file including `TS_AUTHKEY`.

## Prerequisites

- Rootless Podman ≥ 4.4 for Quadlet; tested on Podman 4.9.3 / systemd 255 (Ubuntu 24.04),
  which is what the WOOWTECH hosts run.
- Lingering, so the unit runs without a login session: `install.sh` enables it, or
  `sudo loginctl enable-linger <user>` if polkit refuses.
- UDP `TS_UDP_PORT` (41641 by default) free on the host. `install.sh` checks it.
- Network access to build the image once (about 60 MB of Alpine packages).

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package.git
cd Woow_podman_vpn_tailscale_package
./scripts/install.sh
```

The first run creates the two settings files and stops, so you can edit them:

```bash
$EDITOR ~/.config/woow-tailscale/tailscale.env      # at least TS_HOSTNAME
./scripts/install.sh
```

It then builds the pinned image, renders the unit from the settings (decision D2), checks
it with the Quadlet generator and `systemd-analyze --user verify`, installs it, starts it,
waits for `tailscaled` to report a backend state and runs `tests/smoke.sh`. Re-running it
after a `git pull` or a settings change restarts only what actually changed.

**First login.** With a pre-auth key in `TS_AUTHKEY` the node enrols by itself. Without
one, the install ends with `BackendState=NeedsLogin` and prints where the login URL is:

```bash
podman logs woow-tailscale 2>&1 | grep -m1 -A2 'To authenticate'
```

Clear `TS_AUTHKEY` once the node is enrolled — the identity lives in the state directory
from then on, not in the key.

| Flag | Effect |
|---|---|
| `--state-dir DIR` | record `DIR` as `TS_STATE_DIR` (adopt a node whose identity already lives there) |
| `--rebuild` / `--no-build` | build the pinned image again / never build, it must exist |
| `--build-only` | build the image and stop: no config, no units, no restart (use it before a migration window) |
| `--allow-identity-change` | proceed although `TS_LOGIN_SERVER` or `TS_HOSTNAME` differ from the running node — **this re-registers it: new tailnet IP, serve configuration gone** |
| `--no-start` | install and `daemon-reload`, start nothing |
| `--dry-run` | render, validate and report what would change; touch nothing |

### Settings

Two files, both mode 0600, both created from the examples in `config/`:

| File | Read by | Holds |
|---|---|---|
| `~/.config/woow-tailscale/woow-tailscale.env` | the install and upgrade scripts only | `TS_STATE_DIR`, rendered into the unit |
| `~/.config/woow-tailscale/tailscale.env` | **podman**, as `--env-file` | the node's own `TS_*` settings |

Because podman reads the second file verbatim, it must be plain `KEY=value` lines: no
quotes, no `export`, and **no `# comment` after a value** — podman would keep the comment
text as part of the value and hand it to `tailscale up`. `install.sh` refuses a file that
has them, and so does CI for the examples.

| Key | Default | Effect |
|---|---|---|
| `TS_STATE_DIR` | `%h/.local/share/woow-tailscale/state` | where the node identity lives (in `woow-tailscale.env`; `%h` is expanded by the install script) |
| `TS_LOGIN_SERVER` | *(empty)* | empty = official Tailscale, a URL = self-hosted Headscale |
| `TS_AUTHKEY` | *(empty)* | pre-auth key, first login only |
| `TS_HOSTNAME` | `woow-node` | the node's name on the tailnet; install refuses the example value |
| `TS_ACCEPT_DNS` / `TS_ACCEPT_ROUTES` | `true` | MagicDNS, accept peers' subnet routes |
| `TS_ADVERTISE_ROUTES` | *(empty)* | subnet router, comma separated (`192.168.2.0/24`) |
| `TS_ADVERTISE_EXIT_NODE` / `TS_ADVERTISE_CONNECTOR` | `false` | offer this node as an exit node / app connector |
| `TS_EXIT_NODE` | *(empty)* | use a peer as the exit node |
| `TS_SNAT_SUBNET_ROUTES` / `TS_STATEFUL_FILTERING` | `true` / `false` | subnet-router packet handling |
| `TS_TAGS`, `TS_ALWAYS_USE_DERP` | *(empty)*, `false` | ACL tags; force relayed connections |
| `TS_UDP_PORT` | `41641` | WireGuard port — one node per host per port |
| `TS_WEB_UI` | `false` | `tailscale web`, the node's own admin UI (see below) |
| `TS_EXTRA_UP_ARGS`, `TS_EXTRA_TAILSCALED_ARGS`, `TS_LOG_LEVEL` | *(empty)*, *(empty)*, `info` | passthrough |

`TS_USERSPACE_NETWORKING` and `TS_WEB_LISTEN` are **forced by the unit** and ignored in
this file: podman's `--env` wins over `--env-file`.

### The state directory

`TS_STATE_DIR` is a bind mount, not a named volume, and it is the node itself: machine
key, node key, prefs and the serve configuration. Point it at the directory a previous
deployment used and nothing on the tailnet notices the change — same node ID, same tailnet
IP, same serve forwards.

The unit refuses to start when the directory is missing (`ExecStartPre=test -d`), because
a mistyped path would enrol a brand-new node instead, hand out a new IP and drop every
serve forward. `install.sh` creates only the default path for the same reason.

Two tailscaled processes on one state directory make the keys flap: `install.sh` aborts
when another running container bind-mounts the same path.

### `tailscale web` security

`tailscale web` is a **writable admin UI with no authentication at all** — whoever reaches
it can change this node's settings and log it out. It is off by default, and the unit
forces `TS_WEB_LISTEN=127.0.0.1:8088` so it can never be published on a LAN interface.
Reach it deliberately:

```bash
ssh -L 8088:127.0.0.1:8088 <user>@<host>              # then http://127.0.0.1:8088/
podman exec woow-tailscale tailscale serve --bg --tcp=8088 tcp://127.0.0.1:8088
```

A tailnet serve forward gives it to **every member of the tailnet**. If you need it on the
LAN, do not move the listener: put a reverse proxy with authentication in front of
`127.0.0.1:8088` on the host — `examples/nginx-basic-auth.conf` is a starting point. The
unit's forced listener and `tests/smoke.sh` both treat an 8088 socket outside loopback as
a failure.

### Subnet router and exit node in userspace mode

Both work through the netstack. Set `TS_ADVERTISE_ROUTES` (and/or
`TS_ADVERTISE_EXIT_NODE=true`), re-run `./scripts/install.sh`, then approve the routes in
the admin console. Expect lower throughput than a kernel-mode node; for a busy subnet
router use a dedicated host with kernel mode instead of rootless Podman.

### More than one node on a host

Give the second node its own `TS_UDP_PORT` and its own `TS_STATE_DIR`, and rename the
container and unit. `install.sh` refuses to start a second node on a port that is already
bound.

## Upgrade

```bash
git pull                                   # brings a new pinned tag
./scripts/upgrade.sh                       # on a management path: --watchdog 15m
./scripts/upgrade.sh --commit              # keep it, disarm the watchdog
./scripts/upgrade.sh --rollback            # undo now: previous unit and image
```

It archives the state, builds the new image while the node keeps running, installs and
restarts, then waits for `Running` with **the same node ID and tailnet IP** as before and
runs the smoke test. A failed check puts the previous unit back and restarts on the
previous image by itself.

`--watchdog N` arms a dead-man timer in the lingering user manager first: unless you run
`--commit` within `N`, the previous unit and image come back automatically. Use it
whenever you reach the host through this node's tailnet address, and run the upgrade over
a different path.

## Backup and restore

```bash
./scripts/backup.sh                        # hot: tailscaled writes its state atomically
./scripts/backup.sh --cold                 # stop for the archive (a few seconds down)
./scripts/restore.sh ~/backups/woow-tailscale/<timestamp>
./scripts/restore.sh ~/backups/woow-tailscale/<timestamp> --with-config
```

Each run writes one timestamped directory holding the state directory and both settings
files, 0600 in a 0700 directory with a `.sha256` per file.

**The archive is the node identity, and the settings may hold `TS_AUTHKEY`: treat it like
a private key.** Restoring an identity onto a host while another host still runs it makes
both flap — retire the other one first. `restore.sh` moves the current state directory
aside rather than deleting it, and verifies the node ID after the start.

## Uninstall

```bash
./scripts/uninstall.sh                     # stop and remove the unit; keep the identity
./scripts/uninstall.sh --logout            # leave the tailnet cleanly first
./scripts/uninstall.sh --purge --yes       # also delete the state directory, after a final archive
```

Removing the unit takes the tailnet path to this host down. If that is how you reach it,
keep another way in first. `--purge` destroys the node identity for good.

## Migrating an existing compose or manual deployment

`scripts/migrate-legacy.sh` adopts a running `woow-tailscale` container **keeping its
identity**: the same state directory, so the same node key, the same tailnet IP and the
same serve configuration. A named volume (compose's `*_tailscale-state`, or the old
Quadlet `woow-tailscale-state`) is copied into the new directory while the node is cold; a
bind mount is used in place.

```bash
./scripts/migrate-legacy.sh --dry-run            # what it would derive and do
./scripts/migrate-legacy.sh --watchdog 15m       # the migration itself
./scripts/migrate-legacy.sh --watchdog 15m --allow-broader pi-web   # ... on a host with a coding agent
# ... verify: same node id, same IP, serve forwards answer ...
./scripts/migrate-legacy.sh --commit             # keep it, disarm the watchdog
./scripts/migrate-legacy.sh --rollback           # legacy container back, any time during the soak
./scripts/migrate-legacy.sh --status             # what a migration left behind
./scripts/migrate-legacy.sh --finish             # after the soak: remove the legacy container and unit
```

**Run it over a different path than the tailnet address being migrated.** The protections,
in the order they matter:

- an **SSH-path lock** (`~/.local/state/woow-migrate/ssh-path.lock`), so the two paths into
  one host cannot be migrated on the same day. On a host where a Cloudflare tunnel
  container is the other way in, that migration must take the same lock;
- a **dead-man watchdog**: a transient systemd timer restores the legacy container after
  `--watchdog` (15m by default) unless you run `--commit`;
- the swap runs as a **transient systemd unit**, so losing the terminal cannot leave it
  half done;
- the old and the new container **never run at the same time** (one state directory, one
  UDP port), and a rollback always stops the new one first;
- the go/no-go is the node identity: the same node ID and tailnet IP as before.

It converts the old env file on the way (dropping the Caddy `BASIC_AUTH_*`,
`CADDY_LAN_PORT` and the settings the unit now forces); `--keep-env` leaves an already
converted file alone.

### What the transient units can see

The swap and the watchdog run as transient `systemd --user` units, and `systemd-run --user`
starts a unit from the **user manager's** environment, never from the shell that launched
the migration. A variable you export first therefore reaches the detached half only because
`scripts/watchdog.sh` names it in `TS_DETACHED_ENV` and passes it as `--setenv`
(`QL_PATH_MOUNT_ALLOW`, `WOOW_SSH_PATH_LOCK` and the quadlet-lib path, guard and wait knobs
are there; `QL_DRY_RUN` deliberately is not).

`--allow-broader NAME` (repeatable) is the supported way to set the first one. It declares a
container that legitimately holds a mount *containing* the state directory - pi-web's
`Volume=%h:/host%h` gives the coding agent every path under `$HOME`, so it contains the
tailscale state directory too - and silences the shared library's broader-mount warning for
it. The check that emits that warning runs in `install.sh`, and during a migration
`install.sh` only ever runs **inside the swap unit**, which is exactly where the environment
used to be dropped. `--status` prints the effective allowlist.

**Downtime: the tailnet path and every `tailscale serve` forward are down for roughly
15-30 seconds.**

## Security

- **This node is a path into the host.** Tailnet connections land on host loopback, so
  anything that reaches the node's tailnet address reaches `127.0.0.1` services that
  assume loopback means trusted. Keep tailnet ACLs tight, and remember that a
  `tailscale serve` forward publishes a loopback port to the whole tailnet.
- `tailscale web` is unauthenticated and writable; it is off by default and bound to
  `127.0.0.1` by the unit. See above before turning it on.
- The node runs rootless with no added capabilities and no devices. A container escape
  lands on an unprivileged account.
- The only secret in the settings is `TS_AUTHKEY`, needed for the first login only; clear
  it afterwards. No secret is committed to this repository, and none is written into a
  unit file.
- Backups are the node identity: 0600 files in 0700 directories, and they belong wherever
  you keep private keys.
- The identity guard in `install.sh` and `migrate-legacy.sh` compares `TS_LOGIN_SERVER`
  and `TS_HOSTNAME` against the running node **by hash**, never printing either, and
  refuses a silent re-registration.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `install.sh` refuses: inline comment / quotes / CRLF in the env file | podman's `--env-file` would keep them as part of the value; fix the line |
| `install.sh` refuses: `TS_HOSTNAME` is still `woow-node` | set the node's real tailnet name |
| `install.sh` refuses: state directory does not exist | only the default path is created for you; create it, or point `TS_STATE_DIR` at the existing one |
| `install.sh` refuses: `TS_LOGIN_SERVER`/`TS_HOSTNAME` differ from the running node | that change re-registers the node; `--allow-identity-change` if you mean it |
| `install.sh` refuses: a container named `woow-tailscale` exists | it is not ours; use `scripts/migrate-legacy.sh`, which keeps it for rollback |
| `install.sh` refuses: UDP 41641 in use | another node on this host; set `TS_UDP_PORT` |
| the swap unit's journal warns "sits inside a broader mount held by running container(s)" | a host-file-access container (pi-web's `%h:/host%h`) contains the state directory; re-run with `--allow-broader pi-web`. Exporting `QL_PATH_MOUNT_ALLOW` alone did nothing before the `--setenv` fix |
| `BackendState=NeedsLogin` | no `TS_AUTHKEY`: open the login URL from `podman logs woow-tailscale` |
| Node up, but services on the host are unreachable over the tailnet | they listen on a LAN address only; in userspace mode traffic arrives on `127.0.0.1` |
| Two nodes flapping | two tailscaled on one state directory, or an identity restored onto two hosts |

## Layout

```
quadlet/
  woow-tailscale.container   the unit, with @@TOKENS@@ for per-host values
  render-vars                the only variables install.sh may substitute
config/
  woow-tailscale.env.example -> ~/.config/woow-tailscale/woow-tailscale.env (0600)
  node/tailscale.env.example -> ~/.config/woow-tailscale/tailscale.env      (0600, podman reads it)
scripts/
  install.sh upgrade.sh uninstall.sh backup.sh restore.sh migrate-legacy.sh
  common.sh render-args.sh watchdog.sh
  lib/quadlet-lib.sh         vendored WOOWTECH Quadlet library (do not edit; CI checks its hash)
tests/
  dryrun.sh dryrun.local.sh  render + quadlet -dryrun + systemd-analyze verify (CI)
  smoke.sh                   post-install checks on a real host
  detached-env.sh            the transient units carry the environment they need (CI)
  fixtures/                  per-host variants for the dry-run
Containerfile entrypoint.sh  the image: pinned upstream base + the env-driven entrypoint
examples/nginx-basic-auth.conf  putting auth in front of 127.0.0.1:8088
docs/history/HANDOFF-v1.md   the retired compose + bridge + Caddy design, kept as history
.github/workflows/           quadlet-ci.yml (dry-run, shellcheck), scripts.yml (detached env),
                             image.yml (build + version gate)
```

## Sibling repositories

| Repository | Platform | For |
|---|---|---|
| [`Woow_ha_vpn_tailscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_tailscale_package) | HAOS / HA Supervised | Home Assistant users |
| **this repository** | rootless Podman + systemd | any Linux host |
| [`Woow_ha_vpn_headscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_headscale_package) | HAOS / HA Supervised | self-hosting the control plane |

The three are feature-symmetric and the env names mirror the add-on's option keys, so one
host can run headscale and tailscale side by side and the two meshes interoperate.

| Feature | HA add-on | this repository |
|---|---|---|
| Subnet router / exit node / Taildrop / Serve / Funnel | yes | yes |
| Taildrive HA folders | yes | no (there are no HA folders here) |
| Web UI protection | HA Ingress login | loopback only; put your own auth in front |
| Configuration | HA UI options | `~/.config/woow-tailscale/tailscale.env` |
| Autostart | HA supervisor | systemd user unit, Quadlet |

## License

Package: MIT — see [LICENSE](LICENSE). The upstream Tailscale client is BSD-3-Clause.
