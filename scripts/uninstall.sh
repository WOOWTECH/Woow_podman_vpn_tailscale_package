#!/usr/bin/env bash
# scripts/uninstall.sh: remove the woow-tailscale Quadlet unit. Keeps the node identity.
#
#   scripts/uninstall.sh                    stop + remove the unit; keep the state
#                                           directory, both settings files and the image
#   scripts/uninstall.sh --logout           log the node out of the tailnet first (it
#                                           disappears from the admin console)
#   scripts/uninstall.sh --purge [--yes]    also delete the state directory, after a final
#                                           archive: the node identity is gone for good
#   scripts/uninstall.sh --dry-run          report what would be removed
#
# Removing the unit takes the tailnet path to this host down. If you reach the host only
# over that path, keep another way in.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

purge=0 yes=0 logout=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    --logout) logout=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$TS_APP
ql_require_rootless
ql_lock "$TS_APP"
if ((logout)) && [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  if podman container exists "$TS_CONTAINER" >/dev/null 2>&1; then
    if podman exec "$TS_CONTAINER" tailscale logout; then ql_info "node logged out of the tailnet"; else ql_warn "tailscale logout failed"; fi
  fi
fi
if ((!purge)); then
  ql_uninstall_units "$TS_APP"
  ql_info "kept: the state directory ($(ts_state_dir)), ~/.config/woow-tailscale and the image"
  exit 0
fi
state_dir=$(ts_state_dir)
if ((!yes)) && [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  [[ -t 0 ]] || ql_die "--purge deletes the node identity in $state_dir; add --yes to confirm non-interactively"
  read -r -p "Type 'purge' to delete $state_dir (this node's identity, serve config and prefs): " answer
  [[ $answer == purge ]] || ql_die "aborted; nothing was deleted"
fi
if [[ ${QL_DRY_RUN:-0} != 1 && -d $state_dir ]]; then
  bash "$REPO/scripts/backup.sh" >/dev/null || ql_warn "the final archive failed; continuing"
fi
ql_uninstall_units "$TS_APP" --purge
if [[ ${QL_DRY_RUN:-0} != 1 && -d $state_dir ]]; then
  podman unshare rm -rf -- "$state_dir" || ql_warn "could not remove $state_dir"
  ql_info "removed $state_dir (an archive is in ~/backups/$TS_APP/)"
fi
