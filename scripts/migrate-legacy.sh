#!/usr/bin/env bash
# scripts/migrate-legacy.sh: adopt an existing woow-tailscale container (compose, or a
# hand-written `podman run` unit) as the Quadlet node, KEEPING ITS IDENTITY: the same state
# directory, so the same node key, the same tailnet IP and the same serve configuration.
#
#   scripts/migrate-legacy.sh [--watchdog 15m] [--state-dir DIR] [--keep-env]
#                             [--yes] [--dry-run]
#   scripts/migrate-legacy.sh --commit        keep it; disarm the watchdog
#   scripts/migrate-legacy.sh --rollback      put the legacy container back now
#   scripts/migrate-legacy.sh --status        what a migration left behind
#   scripts/migrate-legacy.sh --finish        after the soak: remove the legacy container
#                                             and unit file, release the SSH-path lock
#
# THIS NODE IS PROBABLY A MANAGEMENT PATH. Run this over a DIFFERENT path (a Cloudflare
# tunnel, the console, the LAN), never over the tailnet address being migrated. The
# protections, in the order they matter:
#
#   - an SSH-path lock (~/.local/state/woow-migrate/ssh-path.lock) so that two migrations
#     of the two paths into a host cannot run on the same day;
#   - a dead-man watchdog: a transient systemd timer restores the legacy container after
#     --watchdog (default 15m) unless you run --commit;
#   - the swap itself runs as a transient systemd unit, so losing the terminal cannot
#     leave it half done;
#   - the old and the new container never run at the same time (one state directory, one
#     UDP port), and a rollback always stops the new one first;
#   - the go/no-go is the node identity: the same node id and tailnet IP as before.
#
# Downtime: the tailnet path and every `tailscale serve` forward are down for roughly
# 15-30 seconds.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=watchdog.sh
. "$REPO/scripts/watchdog.sh"

MSTATE_DIR=$HOME/.local/state/woow-quadlet/woow-tailscale-migrate
MSTATE=$MSTATE_DIR/state
COMMIT_MARKER=$MSTATE_DIR/commit
SSH_LOCK=${WOOW_SSH_PATH_LOCK:-$HOME/.local/state/woow-migrate/ssh-path.lock}
WD_UNIT=woow-ts-watchdog
SWAP_UNIT=woow-ts-swap
export QL_APP=$TS_APP

mode=forward watchdog=15m state_dir_opt='' keep_env=0 yes=0
while (($#)); do
  case $1 in
    --watchdog) watchdog=${2:?--watchdog needs a delay such as 15m}; shift ;;
    --state-dir) state_dir_opt=${2:?--state-dir needs a directory}; shift ;;
    --keep-env) keep_env=1 ;;
    --yes) yes=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    --commit) mode=commit ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --finish) mode=finish ;;
    --swap) mode=swap ;;                     # internal: runs inside the transient unit
    --watchdog-fire) mode=watchdog_fire ;;   # internal: the timer's target
    -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry() { [[ ${QL_DRY_RUN:-0} == 1 ]]; }
state_get() { sed -n "s/^$1=//p" "$MSTATE" 2>/dev/null | tail -n1; }
state_set() { # state_set KEY VALUE
  (umask 077 && mkdir -p "$MSTATE_DIR")
  local tmp=$MSTATE.tmp
  { [[ -f $MSTATE ]] && grep -v "^$1=" "$MSTATE"; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$MSTATE"
}
confirm() {
  ((yes)) && return 0
  [[ -t 0 ]] || ql_die "add --yes to run this non-interactively"
  local a
  read -r -p "$1 [y/N] " a
  [[ $a == [yY] || $a == [yY][eE][sS] ]] || ql_die "aborted; nothing was changed"
}
take_ssh_lock() {
  (umask 077 && mkdir -p "$(dirname "$SSH_LOCK")")
  if mkdir "$SSH_LOCK" 2>/dev/null; then
    printf 'owner=woow-tailscale migration\nsince=%s\npid=%s\n' "$(date -Is)" "$$" >"$SSH_LOCK/owner"
    ql_info "took the SSH-path lock ($SSH_LOCK)"
    return 0
  fi
  if grep -q '^owner=woow-tailscale' "$SSH_LOCK/owner" 2>/dev/null; then
    ql_info "the SSH-path lock is already ours"
    return 0
  fi
  ql_die "another migration holds the SSH-path lock: $(cat "$SSH_LOCK/owner" 2>/dev/null). The two paths into this host must not be migrated on the same day; wait for it to be released"
}
release_ssh_lock() {
  if grep -q '^owner=woow-tailscale' "$SSH_LOCK/owner" 2>/dev/null; then
    rm -rf -- "$SSH_LOCK"
    ql_info "released the SSH-path lock"
  fi
}

# ---- rollback: the new node down first, then the legacy container back --------------------
rollback() {
  local legacy units ip id
  legacy=$(state_get LEGACY_NAME)
  units=$(state_get LEGACY_UNITS)
  ip=$(state_get NODE_IP)
  id=$(state_get NODE_ID)
  if [[ -z $legacy ]]; then
    mapfile -t cands < <(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^woow-tailscale-legacy-' || true)
    ((${#cands[@]} == 1)) || ql_die "no migration state and ${#cands[@]} woow-tailscale-legacy-* containers; roll back by hand"
    legacy=${cands[0]}
  fi
  podman container exists "$legacy" >/dev/null 2>&1 || ql_die "the legacy container $legacy does not exist"
  ql_warn "rolling back: $TS_UNIT out, $legacy back as $TS_CONTAINER"
  systemctl --user stop "$TS_UNIT" 2>/dev/null || true
  ql_wait_until 60 "the Quadlet node to stop" bash -c "[[ \$(podman container inspect --format '{{.State.Running}}' $TS_CONTAINER 2>/dev/null || echo false) != true ]]" || true
  if [[ -f $HOME/.local/state/woow-quadlet/$TS_APP/manifest ]]; then ql_uninstall_units "$TS_APP"; fi
  if podman container exists "$TS_CONTAINER" >/dev/null 2>&1; then
    [[ $(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$TS_CONTAINER" 2>/dev/null) == "$TS_UNIT" ]] \
      || ql_die "a container named $TS_CONTAINER exists that is neither the Quadlet one nor $legacy; resolve by hand"
    podman rm -f "$TS_CONTAINER" >/dev/null
  fi
  podman rename "$legacy" "$TS_CONTAINER"
  if [[ -n $units ]]; then
    for u in $units; do systemctl --user enable "$u" >/dev/null 2>&1 || ql_warn "could not enable $u"; done
    # shellcheck disable=SC2086 # a space-separated list of unit names
    systemctl --user start $units || ql_warn "starting $units failed; falling back to podman start"
  fi
  [[ $(podman container inspect --format '{{.State.Running}}' "$TS_CONTAINER" 2>/dev/null || true) == true ]] || podman start "$TS_CONTAINER" >/dev/null
  if ql_wait_until 120 "the legacy node to report Running" bash -c "[[ \$(podman exec $TS_CONTAINER sh -c 'tailscale status --json 2>/dev/null | jq -r .BackendState' 2>/dev/null) == Running ]]"; then
    local now_ip now_id
    now_ip=$(ts_node_ip "$TS_CONTAINER")
    now_id=$(ts_node_id "$TS_CONTAINER")
    if [[ -n $ip && $now_ip != "$ip" ]]; then ql_warn "the tailnet IP is $now_ip, was $ip"; else ql_info "tailnet IP restored: $now_ip"; fi
    [[ -z $id || $now_id == "$id" ]] || ql_warn "the node id changed ($now_id, was $id)"
  else
    ql_warn "the legacy node is not Running yet; see: podman logs --tail 50 $TS_CONTAINER"
  fi
  state_set PHASE rolled-back
  ts_wd_disarm "$WD_UNIT"
  release_ssh_lock
  ql_warn "rolled back. The Quadlet unit is removed; the state directory was never touched."
}

case $mode in
  status)
    if [[ -f $MSTATE ]]; then sed 's/^/  /' "$MSTATE"; else echo "  no migration state in $MSTATE"; fi
    echo "  watchdog: $(ts_wd_state "$WD_UNIT")   commit marker: $([[ -f $COMMIT_MARKER ]] && echo yes || echo no)"
    echo "  ssh-path lock: $([[ -d $SSH_LOCK ]] && sed -n 's/^owner=/owner /p' "$SSH_LOCK/owner" || echo free)"
    podman ps -a --filter name='^woow-tailscale' --format '  {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || true
    printf '  %s: %s\n' "$TS_UNIT" "$(systemctl --user is-active "$TS_UNIT" 2>/dev/null || true)"
    exit 0 ;;
  commit)
    ql_require_rootless
    [[ $(state_get PHASE) == swapped ]] || ql_warn "the recorded phase is '$(state_get PHASE)', not 'swapped'"
    (umask 077 && mkdir -p "$MSTATE_DIR" && : >"$COMMIT_MARKER")
    ts_wd_disarm "$WD_UNIT"
    state_set PHASE committed
    ql_info "committed: the watchdog is disarmed and the Quadlet node stays."
    ql_info "The legacy container and unit are still there for a manual rollback; run --finish after the soak."
    exit 0 ;;
  rollback)
    ql_require_rootless
    ql_lock woow-tailscale-migrate
    confirm "Put the legacy woow-tailscale container back now?"
    rollback
    exit 0 ;;
  watchdog_fire)
    if [[ -f $COMMIT_MARKER ]]; then ql_info "watchdog: committed; nothing to do"; exit 0; fi
    ql_warn "watchdog: no commit within the deadline; rolling back"
    rollback
    exit 0 ;;
  finish)
    ql_require_rootless
    [[ -f $COMMIT_MARKER ]] || ql_die "not committed yet: run --commit first (and verify the tailnet path from another machine)"
    legacy=$(state_get LEGACY_NAME)
    units=$(state_get LEGACY_UNITS)
    confirm "Remove the legacy container ${legacy:-none} and file away ${units:-no legacy unit}? (no rollback afterwards)"
    if [[ -n $legacy ]] && podman container exists "$legacy" >/dev/null 2>&1; then
      podman rm "$legacy" >/dev/null && ql_info "removed $legacy"
    fi
    for u in $units; do
      f=$HOME/.config/systemd/user/$u
      if [[ -f $f ]]; then
        (umask 077 && mkdir -p "$MSTATE_DIR/legacy-units")
        mv -- "$f" "$MSTATE_DIR/legacy-units/$u"
        ql_info "moved $u to $MSTATE_DIR/legacy-units/ (delete it when you are sure)"
      fi
    done
    systemctl --user daemon-reload
    state_set PHASE finished
    release_ssh_lock
    ql_info "done. The old image can go too: podman images | grep woow-tailscale"
    exit 0 ;;
esac

# ---- the swap, run inside a transient unit ---------------------------------------------------
if [[ $mode == swap ]]; then
  D=$(state_get DATE)
  legacy_name=woow-tailscale-legacy-$D
  units=$(state_get LEGACY_UNITS)
  state_dir=$(state_get STATE_DIR)
  vol=$(state_get STATE_VOLUME)
  ip=$(state_get NODE_IP)
  id=$(state_get NODE_ID)
  B=$(state_get BACKUP_DIR)
  fail() { ql_warn "swap failed: $*"; rollback; exit 1; }
  ql_info "stopping the legacy node"
  for u in $units; do systemctl --user stop "$u" 2>/dev/null || ql_warn "could not stop $u"; done
  podman stop -t 30 "$TS_CONTAINER" >/dev/null 2>&1 || true
  [[ $(podman container inspect --format '{{.State.Running}}' "$TS_CONTAINER" 2>/dev/null || echo false) == false ]] \
    || fail "the legacy container is still running"
  for u in $units; do systemctl --user disable "$u" >/dev/null 2>&1 || ql_warn "could not disable $u"; done
  # cold copy of the identity, now that nothing writes it
  if [[ -n $vol ]]; then
    ql_info "copying the state volume $vol into $state_dir"
    (umask 077 && mkdir -p "$state_dir")
    tmp=$B/state-volume.tar
    podman volume export "$vol" -o "$tmp" || fail "podman volume export $vol failed"
    podman unshare tar -xf "$tmp" -C "$state_dir" || fail "unpacking $tmp into $state_dir failed"
  else
    ql_backup_dir "$state_dir" "$B/state-cold.tgz" >/dev/null || ql_warn "the cold state archive failed"
  fi
  podman rename "$TS_CONTAINER" "$legacy_name" || fail "renaming the legacy container failed"
  state_set LEGACY_NAME "$legacy_name"
  ql_info "legacy container kept as $legacy_name"
  bash "$REPO/scripts/install.sh" --no-build || fail "install.sh failed"
  ql_wait_until 120 "the node to report Running" bash -c "[[ \$(podman exec $TS_CONTAINER sh -c 'tailscale status --json 2>/dev/null | jq -r .BackendState' 2>/dev/null) == Running ]]" \
    || fail "the node did not reach Running"
  now_ip=$(ts_node_ip "$TS_CONTAINER")
  now_id=$(ts_node_id "$TS_CONTAINER")
  [[ -z $ip || $now_ip == "$ip" ]] || fail "the tailnet IP is $now_ip, was $ip (the node re-registered)"
  [[ -z $id || $now_id == "$id" ]] || fail "the node id changed (was $id, now $now_id)"
  bash "$REPO/tests/smoke.sh" --expect-ip "$now_ip" --expect-id "$now_id" || fail "tests/smoke.sh failed"
  state_set PHASE swapped
  ql_info "swap done: the Quadlet node is up as $now_ip with the same node id"
  exit 0
fi

# ---- forward: discovery, preparation, then the detached swap ---------------------------------
ql_preflight 4.4
ql_lock woow-tailscale-migrate
podman container exists "$TS_CONTAINER" >/dev/null 2>&1 \
  || ql_die "no container named $TS_CONTAINER: nothing to migrate (on a fresh host run scripts/install.sh)"
label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$TS_CONTAINER")
[[ $label == "<no value>" ]] && label=''
if [[ $label == "$TS_UNIT" ]]; then ql_info "$TS_CONTAINER is already managed by $TS_UNIT; nothing to migrate"; exit 0; fi
mapfile -t legacy_units < <({ [[ -n $label ]] && printf '%s\n' "$label"; ts_legacy_units; } | sort -u)

# where the identity lives today
state_src='' state_type='' state_vol=''
while IFS='|' read -r mtype mname msrc mdst; do
  [[ $mdst == /var/lib/tailscale ]] || continue
  state_type=$mtype state_vol=$mname state_src=$msrc
done < <(podman inspect --format '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{println}}{{end}}' "$TS_CONTAINER")
[[ -n $state_type ]] || ql_die "the legacy container has nothing mounted at /var/lib/tailscale; its identity would be lost"
if [[ $state_type == bind ]]; then
  state_dir=${state_dir_opt:-$state_src}
  [[ -z $state_dir_opt || $state_dir_opt == "$state_src" ]] \
    || ql_die "--state-dir $state_dir_opt differs from the bind mount the legacy node uses ($state_src); moving the identity is a separate, watchdog-protected step"
  state_vol=''
else
  state_dir=${state_dir_opt:-$HOME/.local/share/woow-tailscale/state}
  ql_warn "the legacy node keeps its identity in the volume '$state_vol'; the swap copies it into $state_dir while the node is stopped"
fi
state_dir=${state_dir%/}
[[ $state_dir == /* ]] || ql_die "the state directory must be an absolute path: '$state_dir'"

# what the node is right now (the go/no-go values)
node_state=$(ts_backend_state "$TS_CONTAINER")
node_ip=$(ts_node_ip "$TS_CONTAINER")
node_id=$(ts_node_id "$TS_CONTAINER")
serve_hash=$(ts_serve_hash "$TS_CONTAINER")
legacy_image=$(podman inspect --format '{{.ImageName}}' "$TS_CONTAINER")
new_image=$(sed -n 's/^Image=//p' "$REPO/quadlet/woow-tailscale.container" | tail -n1)
cat >&2 <<EOF
legacy $TS_CONTAINER: image $legacy_image
  units:      ${legacy_units[*]:-(none; started by hand)}
  identity:   state $state_type ${state_vol:-$state_src} -> $state_dir
  node:       $node_state, ip ${node_ip:-none}, id ${node_id:-none}
  serve hash: ${serve_hash:0:12} (forwards are kept: they live in the state directory)
  new image:  $new_image
EOF
[[ $node_state == Running ]] || ql_warn "the node is '$node_state', not Running: the identity check after the swap will be weaker"

# the node's settings, from what the container actually runs
declare -A want=()
while IFS= read -r line; do
  [[ $line == TS_* ]] || continue
  k=${line%%=*} v=${line#*=}
  [[ $k =~ ^($TS_DROP_KEYS)$ ]] && continue
  if [[ $v =~ [[:space:]]# ]]; then
    v=${v%%[[:space:]]#*}
    v=${v%"${v##*[![:space:]]}"}
    ql_warn "$k had an inline '# comment' in its value (podman --env-file keeps those as data); using the value without it"
  fi
  want[$k]=$v
done < <(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$TS_CONTAINER")
((${#want[@]})) || ql_die "the legacy container has no TS_* environment; refusing to guess its settings"
if dry; then
  ql_info "[dry-run] $TS_NODE_ENV would get: ${!want[*]}"
  ql_info "[dry-run] $TS_INSTALL_ENV would get TS_STATE_DIR=$state_dir"
  ql_info "[dry-run] then: backup, build $new_image, arm a $watchdog watchdog, and swap in a transient unit"
  exit 0
fi
confirm "Migrate this node in place (about 15-30 s of tailnet downtime, watchdog $watchdog)? Make sure you are NOT connected over its tailnet address."

take_ssh_lock
D=$(date +%Y%m%d)
# One directory per attempt: a retry after a rollback on the same day must not collide.
B=$HOME/backups/ts-quadlet-$(date +%Y%m%d-%H%M%S)
(umask 077 && mkdir -p "$B" "$MSTATE_DIR")
ql_env_ensure "$REPO/config/woow-tailscale.env.example" "$TS_INSTALL_ENV"
ql_env_ensure "$REPO/config/node/tailscale.env.example" "$TS_NODE_ENV"
ql_env_set "$TS_INSTALL_ENV" TS_STATE_DIR "$state_dir"
if ((keep_env)); then
  ql_info "--keep-env: $TS_NODE_ENV is used as it is"
else
  for k in $(printf '%s\n' "${!want[@]}" | sort); do ql_env_set "$TS_NODE_ENV" "$k" "${want[$k]}"; done
  ql_info "$TS_NODE_ENV now matches the running node (${#want[@]} settings)"
fi
# keep the legacy artefacts
(
  umask 077
  podman inspect "$TS_CONTAINER" >"$B/woow-tailscale.inspect.json"
  podman inspect --format '{{json .Config.CreateCommand}}' "$TS_CONTAINER" >"$B/woow-tailscale.createcmd.json"
  for u in "${legacy_units[@]}"; do
    f=$HOME/.config/systemd/user/$u
    [[ -f $f ]] && cp -p -- "$f" "$B/"
  done
)
if [[ $state_type == bind ]]; then
  ql_backup_dir "$state_src" "$B/state-hot.tgz" >/dev/null || ql_warn "the hot state archive failed"
fi
bash "$REPO/scripts/install.sh" --build-only || ql_die "building $new_image failed; nothing else was changed"
state_set DATE "$D"
state_set PHASE prepared
state_set LEGACY_UNITS "${legacy_units[*]}"
state_set STATE_DIR "$state_dir"
state_set STATE_VOLUME "$state_vol"
state_set NODE_IP "$node_ip"
state_set NODE_ID "$node_id"
state_set BACKUP_DIR "$B"
rm -f "$COMMIT_MARKER"

# ---- arm the watchdog, then swap in a transient unit ------------------------------------------
ts_wd_arm "$WD_UNIT" "$watchdog" /bin/bash "$REPO/scripts/migrate-legacy.sh" --watchdog-fire --yes
ts_run_detached "$SWAP_UNIT" /bin/bash "$REPO/scripts/migrate-legacy.sh" --swap --yes
ql_info "the swap is running as $SWAP_UNIT.service; following it (losing this terminal is safe):"
ql_info "    journalctl --user -u $SWAP_UNIT -f -o cat"
rc=0
ts_wait_unit "$SWAP_UNIT" 600 || rc=$?
journalctl --user -u "$SWAP_UNIT" -n 40 --no-pager -o cat 2>/dev/null || true
if ((rc == 0)) && [[ $(state_get PHASE) == swapped ]]; then
  cat >&2 <<EOF

The Quadlet node is up with the same identity: ${node_ip:-?} (node id ${node_id:-?}).
The watchdog rolls this back in $watchdog unless you commit.

  1. from ANOTHER machine, check the tailnet path: ssh, tailscale ping, your serve forwards
  2. keep it:      scripts/migrate-legacy.sh --commit
     undo it now:  scripts/migrate-legacy.sh --rollback
  3. after the soak period: scripts/migrate-legacy.sh --finish

  Backup: $B
EOF
  exit 0
fi
ql_warn "the swap did not finish cleanly (see the log above)."
ql_warn "It rolls itself back on failure; the watchdog would do it at the deadline. Check with --status."
exit 1
