#!/usr/bin/env bash
# scripts/restore.sh: put this node's identity back from a scripts/backup.sh run.
#
#   scripts/restore.sh <DIR|tailscale-state.tgz> [--yes] [--with-config]
#
#   --with-config  also restore woow-tailscale.env and tailscale.env from the run directory
#
# The node is stopped, the current state directory is moved aside (never deleted), the
# archive is unpacked in its place, and the node is started and checked. Restoring an
# identity onto a host while another host still runs it makes both flap: retire the other
# one first.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

src='' yes=0 with_config=0
while (($#)); do
  case $1 in
    --yes) yes=1 ;;
    --with-config) with_config=1 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $src ]] || ql_die "one archive or directory only"; src=$1 ;;
  esac
  shift
done
[[ -n $src ]] || ql_die "usage: scripts/restore.sh <backup directory or tailscale-state.tgz> [--yes]"
ql_require_rootless
ql_lock "$TS_APP"
dir=''
if [[ -d $src ]]; then dir=$src; archive=$src/tailscale-state.tgz; else archive=$src; dir=$(dirname -- "$src"); fi
[[ -f $archive ]] || ql_die "$archive not found"
if [[ -f $archive.sha256 ]]; then
  (cd -- "$(dirname -- "$archive")" && sha256sum -c --quiet -- "$(basename -- "$archive").sha256") || ql_die "checksum mismatch for $archive"
  ql_info "checksum ok: $archive"
fi
state_dir=$(ts_state_dir)
[[ -n $state_dir ]] || ql_die "TS_STATE_DIR is not set in $TS_INSTALL_ENV"
base=${state_dir##*/} parent=${state_dir%/*}
tar -tzf "$archive" | head -n1 | grep -q "^$base/" || ql_die "$archive does not contain a '$base/' directory; it was made for a different state path"
if ((!yes)); then
  [[ -t 0 ]] || ql_die "restore replaces $state_dir; add --yes to confirm non-interactively"
  read -r -p "Replace the node identity in $state_dir with $archive? Type 'restore': " answer
  [[ $answer == restore ]] || ql_die "aborted; nothing was changed"
fi
systemctl --user stop "$TS_UNIT" 2>/dev/null || true
[[ $(podman container inspect --format '{{.State.Running}}' "$TS_CONTAINER" 2>/dev/null || true) != true ]] \
  || ql_die "$TS_CONTAINER is still running; stop whatever starts it first"
if [[ -d $state_dir ]]; then
  aside=$state_dir.pre-restore-$(date +%Y%m%d-%H%M%S)
  mv -- "$state_dir" "$aside"
  ql_info "moved the current state aside: $aside"
fi
(umask 077 && mkdir -p "$parent")
podman unshare tar -xzf "$archive" -C "$parent" || ql_die "cannot unpack $archive into $parent"
[[ -d $state_dir ]] || ql_die "$archive did not restore $state_dir"
if ((with_config)); then
  for f in woow-tailscale.env tailscale.env; do
    [[ -f $dir/$f ]] || continue
    install -m 600 -- "$dir/$f" "$HOME/.config/woow-tailscale/$f"
    ql_info "restored ~/.config/woow-tailscale/$f"
  done
fi
systemctl --user start "$TS_UNIT"
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$TS_CONTAINER" 120 || ql_warn "$TS_CONTAINER is not healthy yet"
ql_wait_until 120 "the node to report Running" bash -c "[[ \$(podman exec $TS_CONTAINER sh -c 'tailscale status --json 2>/dev/null | jq -r .BackendState' 2>/dev/null) == Running ]]" \
  || ql_warn "the node is not Running yet; see: podman logs --tail 50 $TS_CONTAINER"
bash "$REPO/tests/smoke.sh"
