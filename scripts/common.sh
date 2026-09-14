# shellcheck shell=bash
# scripts/common.sh: helpers shared by the woow-tailscale scripts.
# Source it after scripts/lib/quadlet-lib.sh.

# shellcheck disable=SC2034 # read by the scripts that source this file
TS_APP=woow-tailscale
# shellcheck disable=SC2034
# Overridable, but see ts_require_legacy_container: pointing this at a container of a
# different lineage (woowtechopenclaw's woow-tailscale-gateway) is refused, not adopted.
TS_CONTAINER=${TS_CONTAINER:-woow-tailscale}
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

# ts_legacy_units: user units that start or stop a container named $TS_CONTAINER.
#
# The name is anchored on whitespace-or-end, not on `\b`. A word boundary sits between
# "woow-tailscale" and the "-" of "woow-tailscale-gateway", so `\bwoow-tailscale\b` matched
# `ExecStart=/usr/bin/podman run --name woow-tailscale-gateway` - openclaw's live gateway,
# a different lineage - and a name override would then have handed its unit to the swap,
# which stops and disables what it discovers. tests/host-tree.sh pins that negative case.
#
# The argument between the verb and the name is OPTIONAL. An earlier anchoring wrote
# `...(start|stop|run|restart)[[:space:]].*[[:space:]]$n(...)`, whose `.*[[:space:]]`
# demanded a SECOND whitespace run after the verb - so the canonical
# `ExecStart=/usr/bin/podman start woow-tailscale` was NOT discovered, while
# `ExecStop=/usr/bin/podman stop -t 10 woow-tailscale` was. An undiscovered unit is never
# stopped and never `systemctl --user disable`d by migrate-legacy.sh, and on a host where
# podman-restart.service is enabled (woowtechopenclaw) it revives the container at the next
# boot against the Quadlet-managed one. tests/host-tree.sh now pins one case per Exec form.
ts_legacy_units() {
  local d=$HOME/.config/systemd/user f n=$TS_CONTAINER
  [[ -d $d ]] || return 0
  # the name, optionally quoted, anchored on whitespace-or-end
  local q='["'"'"']?'
  local name="${q}${n}${q}([[:space:]]|\$)"
  local ex='^[[:space:]]*Exec(Start|StartPre|StartPost|Stop|StopPost|Reload)='
  for f in "$d"/*.service; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == "$TS_UNIT" ]] && continue
    if grep -qE "$ex.*[[:space:]](start|stop|run|restart|kill|rm|create)[[:space:]]+(.*[[:space:]])?$name" "$f" \
      || grep -qE "$ex.*[[:space:]]--name[= ]$name" "$f"; then
      printf '%s\n' "${f##*/}"
    fi
  done
}

# ts_unit_hooks <unit name>: every Exec*Pre / Exec*Post line of a user unit, plus a marker
# for a drop-in directory, one per line as "<key>=<value>". Nothing in migrate-legacy.sh
# reproduces these, and on woowtechopenclaw they run resource_ownership.py and
# apply-official-services.sh out of a non-git tree, so their presence is a refusal.
ts_unit_hooks() {
  local d=$HOME/.config/systemd/user f=$HOME/.config/systemd/user/$1
  [[ -f $f ]] || return 0
  sed -n 's/^[[:space:]]*\(Exec\(StartPre\|StartPost\|StopPost\|Reload\|Condition\)=.*\)/\1/p' "$f"
  local dropin
  for dropin in "$d/$1.d"/*.conf; do
    [[ -f $dropin ]] || continue
    printf 'drop-in=%s\n' "${dropin##*/}"
    sed -n 's/^[[:space:]]*\(Exec[A-Za-z]*=.*\)/\1/p' "$dropin"
  done
  return 0
}

# ts_similar_containers: containers whose name starts with $TS_CONTAINER but is not it.
ts_similar_containers() {
  podman ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -E "^$TS_CONTAINER" | grep -vx "$TS_CONTAINER" || true
  return 0
}

# ts_require_legacy_container: the container this package adopts must exist under exactly
# the name this package uses. When it does not but a woow-tailscale* container does, that
# host runs tailscale from a different lineage - openclaw's woow-tailscale-gateway is built
# from a Containerfile and entrypoint.sh that diverged by ~170 lines and is pinned by image
# ID - and the old advice here ("on a fresh host run scripts/install.sh") was the worst
# possible answer: install.sh would build and start a SECOND node against the same tailnet
# identity. So that suggestion is made only when nothing tailscale-shaped is running.
ts_require_legacy_container() {
  podman container exists "$TS_CONTAINER" >/dev/null 2>&1 && return 0
  local -a similar=()
  mapfile -t similar < <(ts_similar_containers)
  ((${#similar[@]})) || ql_die "no container named $TS_CONTAINER: nothing to migrate (on a fresh host run scripts/install.sh)"
  local c unit
  for c in "${similar[@]}"; do
    unit=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c" 2>/dev/null)
    [[ $unit == "<no value>" || -z $unit ]] && unit=$(TS_CONTAINER=$c ts_legacy_units | tr '\n' ' ')
    ql_warn "found $c (unit: ${unit:-unknown})"
  done
  ql_die "no container named $TS_CONTAINER, but this host runs ${similar[*]} from a different lineage. Do NOT run scripts/install.sh here: it would build and start a second tailscale node against the same tailnet identity, and that node's image is pinned by ID and built from a diverged Containerfile/entrypoint.sh that this repo cannot reproduce. Migrating it is a separate, planned window"
}

# ts_require_reproducible_units <unit>...: refuse units whose behaviour the Quadlet unit does
# not carry over. migrate-legacy.sh reads neither drop-ins nor Exec*Pre/Post, so a unit that
# has them would lose that behaviour the moment the swap disables it.
ts_require_reproducible_units() {
  local u hooks
  for u in "$@"; do
    hooks=$(ts_unit_hooks "$u")
    [[ -n $hooks ]] || continue
    ql_die "the legacy unit $u carries hooks this package does not reproduce:"$'\n'"${hooks//$'\n'/$'\n'  }"$'\n'"scripts/install.sh writes a plain Quadlet unit with none of them, and the swap stops and disables $u, so that behaviour would simply be gone. Port it into quadlet/ (or a fragment) before migrating this host"
  done
  return 0
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
