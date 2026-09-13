#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; cd "$ROOT"
[[ $# == 1 ]] || { echo "usage: $0 ABSOLUTE-NEW-ARCHIVE" >&2; exit 2; }
out="$1"; [[ "$out" == /* && ! -e "$out" ]] || { echo 'backup path must be absolute and new' >&2; exit 2; }
case "$out" in "$ROOT"/*) echo 'backup must be outside the repository' >&2; exit 2;; esac
parent="$(dirname "$out")"; [[ -d "$parent" ]] || { echo 'backup parent does not exist' >&2; exit 2; }
canonical_parent="$(realpath -e "$parent")"; canonical_out="${canonical_parent%/}/$(basename "$out")"; [[ "$canonical_parent" == "$parent" && "$out" == "$canonical_out" ]] || { echo 'backup path must not traverse symlinks' >&2; exit 2; }
if [[ "${WOOW_GATEWAY_LOCK_HELD:-0}" != 1 ]]; then exec 9>"${XDG_RUNTIME_DIR:-$ROOT/runtime}/woow-tailscale-gateway.lock"; flock -x 9; export WOOW_GATEWAY_LOCK_HELD=1; fi
python3 scripts/resource_ownership.py check-container "$ROOT"
python3 scripts/resource_ownership.py check-volume "$ROOT"
stage="$(mktemp -d "$parent/.woow-gateway-backup.XXXXXX")"; chmod 700 "$stage"; temp="$(mktemp "$parent/.$(basename "$out").new.XXXXXX")"; chmod 600 "$temp"
was_active=false; stopped=false; node_before=''
restart() {
 rc=$?; trap - EXIT INT TERM
 if [[ "$stopped" == true ]]; then
  recovered=''
  if ! systemctl --user start woow-tailscale-gateway.service || ! scripts/verify.sh >/dev/null || ! recovered="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')" || [[ -z "$node_before" || "$recovered" != "$node_before" ]]; then
   echo 'CRITICAL: backup failed and exact prior gateway identity could not be verified after restart' >&2; rc=1
  else
   echo 'Backup failed; gateway restarted with exact prior Self.ID verified.' >&2
  fi
 fi
 rm -rf "$stage"; rm -f "$temp"; exit "$rc"
}
trap restart EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
systemctl --user is-active --quiet woow-tailscale-gateway.service && was_active=true
[[ "$was_active" == true ]] || { echo 'gateway service must be active' >&2; exit 1; }
node_before="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"
[[ "$node_before" == "$(<runtime/gateway-self-id)" ]] || { echo 'gateway identity differs from persisted Self.ID before backup' >&2; exit 1; }
# Install the recovery obligation before stop so interruption cannot strand it.
stopped=true
systemctl --user stop woow-tailscale-gateway.service
podman volume export --output "$stage/state.tar" woow-tailscale-gateway-state
chmod 600 "$stage/state.tar"
image="$(podman image inspect localhost/woow-tailscale-gateway:latest --format '{{.Id}}')"
labels="$(podman volume inspect woow-tailscale-gateway-state | jq -c '.[0].Labels')"
python3 - "$stage/manifest.json" "$ROOT" "$node_before" "$image" "$labels" <<'PY'
import json,sys
p,root,node,image,labels=sys.argv[1:]
with open(p,'w') as f: json.dump({'schema':2,'checkout':root,'commit':__import__('subprocess').check_output(['git','rev-parse','HEAD'],text=True).strip(),'self_id':node,'image_id':image,'volume':'woow-tailscale-gateway-state','volume_labels':json.loads(labels)},f,sort_keys=True);f.write('\n')
PY
chmod 600 "$stage/manifest.json"; (cd "$stage" && sha256sum manifest.json state.tar >SHA256SUMS); chmod 600 "$stage/SHA256SUMS"
tar -C "$stage" -cf "$temp" manifest.json SHA256SUMS state.tar; chmod 600 "$temp"
systemctl --user start woow-tailscale-gateway.service
scripts/verify.sh >/dev/null
node_after="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"; [[ "$node_after" == "$node_before" ]] || { echo 'gateway identity changed after backup' >&2; exit 1; }
stopped=false
[[ ! -e "$out" ]]; mv -T --no-clobber "$temp" "$out"; [[ ! -e "$temp" ]] || { echo 'backup destination became occupied' >&2; exit 1; }
trap - EXIT INT TERM; rm -rf "$stage"
echo "Cold backup created: $out"
