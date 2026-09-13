# shellcheck shell=bash
# scripts/common.sh: helpers shared by the woow-tailscale scripts.
# Source it after scripts/lib/quadlet-lib.sh.

# shellcheck disable=SC2034 # read by the scripts that source this file
TS_APP=woow-tailscale
# shellcheck disable=SC2034
TS_CONTAINER=woow-tailscale
# shellcheck disable=SC2034
TS_UNIT=woow-tailscale.service
# shellcheck disable=SC2034
TS_INSTALL_ENV=$HOME/.config/woow-tailscale/woow-tailscale.env
# shellcheck disable=SC2034
TS_NODE_ENV=$HOME/.config/woow-tailscale/tailscale.env
# Settings the unit forces, or that belonged to the removed Caddy sidecar: never copied
# into the node env file by scripts/migrate-legacy.sh.
# shellcheck disable=SC2034
TS_DROP_KEYS='TS_USERSPACE_NETWORKING|TS_WEB_LISTEN|BASIC_AUTH_USER|BASIC_AUTH_HASH|CADDY_LAN_PORT|TAILSCALE_UPSTREAM|TINI_SUBREAPER'

# ts_env_value <file> <KEY> [default]: one value, without loading the file into QL_ENV
ts_env_value() {
  local v
  v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1)
  printf '%s' "${v:-${3:-}}"
}

# ts_state_dir: TS_STATE_DIR from the install env file, with %h expanded
ts_state_dir() { ql_expand_home "$(ts_env_value "$TS_INSTALL_ENV" TS_STATE_DIR)"; }

# ts_legacy_units: user units that start or stop a container named woow-tailscale
ts_legacy_units() {
  local d=$HOME/.config/systemd/user f
  [[ -d $d ]] || return 0
  for f in "$d"/*.service; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == "$TS_UNIT" ]] && continue
    if grep -qE '^[[:space:]]*Exec(Start|StartPre|Stop)=.*[[:space:]](start|stop|run|restart)[[:space:]].*\bwoow-tailscale\b' "$f" \
      || grep -qE '^[[:space:]]*Exec(Start|Stop)=.*[[:space:]]--name[= ]woow-tailscale\b' "$f"; then
      printf '%s\n' "${f##*/}"
    fi
  done
}

# ts_status <container>: BackendState, node ID, first tailnet IP and hostname, one line.
# jq lives in the image, so nothing is needed on the host.
ts_status() {
  podman exec "$1" sh -c 'tailscale status --json 2>/dev/null | jq -r "[.BackendState, (.Self.ID // \"-\"), (.Self.TailscaleIPs[0] // \"-\"), (.Self.HostName // \"-\")] | @tsv"' 2>/dev/null || true
}
ts_backend_state() { ts_status "$1" | cut -f1; }
ts_node_id() { ts_status "$1" | cut -f2; }
ts_node_ip() { ts_status "$1" | cut -f3; }
# ts_serve_hash <container>: sha256 of the serve configuration (never prints its content)
ts_serve_hash() {
  podman exec "$1" sh -c 'tailscale serve status --json 2>/dev/null || true' 2>/dev/null | sha256sum | cut -d' ' -f1
}

# ts_allow_broader <container>: add <container> to QL_PATH_MOUNT_ALLOW, the broader-mount
# allowlist that quadlet-lib's ql_check_path_mounted reads, and export it so it reaches
# scripts/install.sh - including the copy that runs inside the detached swap unit, which
# gets it only because scripts/watchdog.sh names it in TS_DETACHED_ENV. Repeatable; the
# library spells the same thing `ql_check_path_mounted --allow-broader NAME`.
ts_allow_broader() {
  local name=${1:?usage: ts_allow_broader <container>}
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || ql_die "--allow-broader takes a container name, not '$name'"
  QL_PATH_MOUNT_ALLOW="${QL_PATH_MOUNT_ALLOW:+$QL_PATH_MOUNT_ALLOW }$name"
  export QL_PATH_MOUNT_ALLOW
}

# ---- the legacy rollback model (STANDARD 7a; quadlet-lib >= 1.4.0) -----------------------
# Keeping the legacy containers renamed and stopped is a rollback path only while nothing
# starts them again. The user unit podman-restart.service runs
# `podman start --all --filter restart-policy=always` at boot, so where it is enabled a
# renamed, stopped container whose policy is exactly `always` revives and fights the new
# Quadlet container for its name, ports and volumes. podman 4.9.3 cannot defuse that in
# place - `podman update` is cgroup-only, a restart policy is fixed at create time - so the
# answer there is to capture the container and remove it. ql_rollback_strategy asks this
# host (is that unit enabled, what is each container's policy) and answers `rename` or
# `capture`; it never looks at a host name.

# ts_legacy_capture <backup dir> <container>...: write the rollback copy of each container.
# Read-only towards the containers, so it belongs in the prepare phase, before any downtime:
# a container the library cannot replay (an empty CreateCommand - created through the podman
# API rather than the CLI) is refused here, while the legacy stack is still running.
ts_legacy_capture() {
  local bk=${1:?usage: ts_legacy_capture <backup dir> <container>...} c meta
  shift
  for c in "$@"; do
    meta=$bk/legacy-container/$c/meta
    if [[ -f $meta ]]; then
      ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
    else
      ql_capture_container "$c" "$bk" >/dev/null
    fi
    [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
      "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy containers can simply be renamed) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
  done
}

# ts_legacy_retire <strategy> <suffix> <backup dir> <container>...: take the legacy
# containers out of the new stack's way, in the shape the strategy asked for.
ts_legacy_retire() {
  # The suffix is empty on the capture path: nothing is renamed there, so there is no
  # <name>-legacy-<suffix> to name. ${2-} rather than ${2:?}, which would abort the script.
  local strategy=${1:?} sfx=${2-} bk=${3:?} c
  shift 3
  for c in "$@"; do
    case $strategy in
      rename)
        [[ -n $sfx ]] || ql_die "the rename path needs a suffix for $c-legacy-<suffix>"
        podman rename "$c" "$c-legacy-$sfx" || ql_die "podman rename $c failed"
        ql_info "renamed $c -> $c-legacy-$sfx (stopped, kept for --rollback)" ;;
      capture)
        [[ -f $bk/legacy-container/$c/meta ]] || ql_die "no rollback copy of $c in $bk; nothing was removed"
        # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes that the
        # capture records and expects to find again.
        podman rm "$c" >/dev/null || ql_die "podman rm $c failed"
        ql_info "removed $c; --rollback recreates it from $bk/legacy-container/$c" ;;
      *) ql_die "unknown rollback strategy '$strategy'" ;;
    esac
  done
}

# ts_legacy_restore <suffix> <backup dir> <container>...: bring the legacy containers back,
# whichever shape the cutover used. A recreated container comes back stopped and with its
# original restart policy; the caller starts it, exactly as it starts a renamed one.
ts_legacy_restore() {
  # An empty suffix means the cutover captured rather than renamed: there is no
  # <name>-legacy-<suffix> to look for, only the rollback copy.
  local sfx=${1-} bk=${2:?} c
  shift 2
  for c in "$@"; do
    if [[ -n $sfx ]] && podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container ${sfx:+$c-legacy-$sfx }nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}
