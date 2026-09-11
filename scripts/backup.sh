#!/usr/bin/env bash
# scripts/backup.sh: archive the tailscale state directory (this node's identity: machine
# key, node key, prefs and the serve configuration) and both settings files.
#
#   scripts/backup.sh [--cold] [--dest DIR]
#
#   (default)   hot: tailscaled writes its state atomically, so a running node is fine
#   --cold      stop the node for the archive (the tailnet path drops for a few seconds)
#   --dest DIR  parent directory, default ~/backups/woow-tailscale; each run writes
#               DIR/<timestamp>/
#
# Prints the run directory. Files are 0600 in 0700 directories with a .sha256 each.
# THE ARCHIVE IS THE NODE IDENTITY, and the settings file may hold TS_AUTHKEY: treat it
# like a private key. Restore with scripts/restore.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

parent=$HOME/backups/$TS_APP cold=0
while (($#)); do
  case $1 in
    --cold) cold=1 ;;
    --dest) parent=${2:?--dest needs a directory}; shift ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
state_dir=$(ts_state_dir)
[[ -n $state_dir && -d $state_dir ]] || ql_die "state directory '${state_dir:-unset}' does not exist (is $TS_INSTALL_ENV set up?)"
dest=$parent/$(date +%Y%m%d-%H%M%S)
[[ ! -e $dest ]] || ql_die "$dest already exists"

restart=0
if ((cold)) && systemctl --user is-active --quiet "$TS_UNIT"; then
  restart=1
  trap 'systemctl --user start "$TS_UNIT" || ql_warn "could not start $TS_UNIT again; run: systemctl --user start $TS_UNIT"' EXIT
  ql_info "stopping $TS_UNIT for a cold archive (the tailnet path drops meanwhile)"
  systemctl --user stop "$TS_UNIT"
fi
ql_backup_dir "$state_dir" "$dest/tailscale-state.tgz" >/dev/null
for f in "$TS_INSTALL_ENV" "$TS_NODE_ENV"; do
  [[ -f $f ]] || continue
  (umask 077 && cp -p -- "$f" "$dest/")
done
(cd -- "$dest" && umask 077 && sha256sum -- * >SHA256SUMS 2>/dev/null || true)
((restart)) && ql_info "starting $TS_UNIT again"
ql_info "backup complete: $dest"
printf '%s\n' "$dest"
