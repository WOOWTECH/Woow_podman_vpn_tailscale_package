#!/usr/bin/env bash
# scripts/upgrade.sh: move the node to the image pinned in quadlet/woow-tailscale.container
# (run it after a `git pull` that bumped the tag), keeping the node identity.
#
#   scripts/upgrade.sh [--no-backup] [--watchdog 15m]
#   scripts/upgrade.sh --commit          keep the upgrade and disarm the watchdog
#   scripts/upgrade.sh --rollback        undo it now (previous unit and image)
#
# --watchdog arms a dead-man timer first: unless you run --commit, the previous unit and
# image come back automatically. Use it whenever you reach this host through its tailnet
# address, and drive the upgrade over a different path (a Cloudflare tunnel, the console).
#
# Steps: archive the state, build the new image while the node keeps running, install and
# restart, wait for Running with the SAME node id and tailnet IP, run tests/smoke.sh. A
# failed check puts the previous unit back and restarts on the previous image.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=watchdog.sh
. "$REPO/scripts/watchdog.sh"

QDIR=$HOME/.config/containers/systemd
STATE=$HOME/.local/state/woow-quadlet/$TS_APP
WD_UNIT=woow-ts-upgrade-watchdog
COMMIT_MARKER=$STATE/upgrade.commit
export QL_APP=$TS_APP
mode=upgrade backup=1 watchdog=''
while (($#)); do
  case $1 in
    --no-backup) backup=0 ;;
    --watchdog) watchdog=${2:?--watchdog needs a delay such as 15m}; shift ;;
    --commit) mode=commit ;;
    --rollback) mode=rollback ;;
    --watchdog-fire) mode='watchdog-fire' ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless

rollback_to_previous() { # rollback_to_previous <rollback-dir>
  local rb=$1 prev
  [[ -d $rb ]] || ql_die "no rollback copy in $rb"
  prev=$(sed -n 's/^Image=//p' "$rb/woow-tailscale.container" | tail -n1)
  ql_warn "rolling back to $prev"
  podman image exists "$prev" >/dev/null 2>&1 || ql_die "the previous image $prev is gone; cannot roll back automatically"
  install -m 0644 -- "$rb/woow-tailscale.container" "$QDIR/woow-tailscale.container"
  [[ -f $rb/manifest ]] && cp -p -- "$rb/manifest" "$STATE/manifest"
  systemctl --user daemon-reload
  systemctl --user restart "$TS_UNIT" || ql_die "rollback: $TS_UNIT does not start; see journalctl --user -u $TS_UNIT -n 100"
  QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$TS_CONTAINER" 120 || ql_warn "rollback: the node is not healthy yet"
  bash "$REPO/tests/smoke.sh" || ql_warn "rollback: smoke checks failed"
  ql_info "rolled back to $prev"
}
latest_rollback_dir() { find "$STATE" -maxdepth 1 -name 'upgrade-*' -type d 2>/dev/null | sort | tail -n1; }

case $mode in
  commit)
    (umask 077 && mkdir -p "$STATE" && : >"$COMMIT_MARKER")
    ts_wd_disarm "$WD_UNIT"
    ql_info "upgrade committed; watchdog disarmed"
    exit 0 ;;
  rollback)
    ts_wd_disarm "$WD_UNIT"
    rollback_to_previous "$(latest_rollback_dir)"
    exit 0 ;;
  'watchdog-fire')
    if [[ -f $COMMIT_MARKER ]]; then ql_info "watchdog: the upgrade was committed; nothing to do"; exit 0; fi
    ql_warn "watchdog: no commit within the deadline; rolling back"
    rollback_to_previous "$(latest_rollback_dir)"
    exit 0 ;;
esac

ql_require_podman_min 4.4
[[ -f $QDIR/woow-tailscale.container ]] || ql_die "woow-tailscale is not installed by this package yet; run scripts/install.sh"
prev_image=$(sed -n 's/^Image=//p' "$QDIR/woow-tailscale.container" | tail -n1)
new_image=$(sed -n 's/^Image=//p' "$REPO/quadlet/woow-tailscale.container" | tail -n1)
ql_info "installed: $prev_image; repo pins: $new_image"
prev_id=$(ts_node_id "$TS_CONTAINER")
prev_ip=$(ts_node_ip "$TS_CONTAINER")
[[ -n $prev_ip && $prev_ip != - ]] || ql_warn "the node has no tailnet IP right now; the identity check after the upgrade will be weaker"

if ((backup)); then
  bash "$REPO/scripts/backup.sh" >/dev/null || ql_die "backup failed; nothing was changed (use --no-backup to skip it)"
fi
bash "$REPO/scripts/install.sh" --build-only || ql_die "building $new_image failed; nothing was changed"

rb=$STATE/upgrade-$(date +%Y%m%d-%H%M%S)
(umask 077 && mkdir -p "$rb")
cp -p -- "$QDIR/woow-tailscale.container" "$rb/"
[[ -f $STATE/manifest ]] && cp -p -- "$STATE/manifest" "$rb/"
rm -f "$COMMIT_MARKER"
if [[ -n $watchdog ]]; then
  ts_wd_arm "$WD_UNIT" "$watchdog" /bin/bash "$REPO/scripts/upgrade.sh" --watchdog-fire
  ql_warn "verify the tailnet path from ANOTHER machine, then run: scripts/upgrade.sh --commit"
fi

ok=1
bash "$REPO/scripts/install.sh" --no-build || ok=0
if ((ok)); then
  args=()
  [[ -n $prev_ip && $prev_ip != - ]] && args+=(--expect-ip "$prev_ip")
  [[ -n $prev_id && $prev_id != - ]] && args+=(--expect-id "$prev_id")
  bash "$REPO/tests/smoke.sh" "${args[@]}" || ok=0
fi
if ((ok)); then
  ql_info "upgraded: $prev_image -> $new_image; node identity unchanged"
  if [[ -n $watchdog ]]; then
    ql_warn "the watchdog is still armed: confirm the tailnet path works, then run scripts/upgrade.sh --commit"
  fi
  exit 0
fi
ql_warn "the upgrade did not verify"
if [[ -n $watchdog ]]; then
  ql_warn "leaving the watchdog to roll back, or run: scripts/upgrade.sh --rollback"
  exit 1
fi
rollback_to_previous "$rb"
exit 1
