#!/usr/bin/env bash
# Irreversible Matter Server retirement. This file only defines the guarded
# operation; it is never run automatically by deploy, verify, or tests.
set -Eeuo pipefail
umask 077
[[ $# == 1 && "$1" == --confirm-permanent-matter-removal ]] || { echo 'literal --confirm-permanent-matter-removal is required' >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; cd "$ROOT"
lock_dir="${XDG_RUNTIME_DIR:-$ROOT/runtime}"; mkdir -p "$lock_dir"; chmod 700 "$lock_dir"
exec 9>"$lock_dir/woow-tailscale-gateway.lock"; flock -x 9
export WOOW_GATEWAY_LOCK_HELD=1
work="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/matter-removal.XXXXXX")"; chmod 700 "$work"
mutation_started=false; backup=''
cleanup(){ rc=$?; trap - EXIT; rm -rf "$work"; exit "$rc"; }
on_error(){ rc=$?; if [[ "$mutation_started" == true ]]; then echo "CRITICAL: Matter removal started and failed; Matter is not recreated automatically. Gateway backup: ${backup:-unavailable}" >&2; fi; return "$rc"; }
trap on_error ERR
trap cleanup EXIT
snapshot_containers(){
  local ids; ids="$(podman ps -aq)"
  if [[ -n "$ids" ]]; then podman inspect $ids; else printf '[]\n'; fi
}

# Fresh gates only. last-verification.json is evidence, never authorization.
snapshot_containers >"$work/initial-containers.json"
systemctl --user list-unit-files --type=service --no-legend >"$work/initial-user-units.txt"
python3 -m unittest discover -s tests -v
bash -n entrypoint.sh scripts/*.sh
git diff --check
python3 -m unittest tests.test_secret_scan -v
scripts/verify.sh
scripts/live-test.sh
node_before="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"
[[ "$node_before" == "$(<runtime/gateway-self-id)" ]] || { echo 'gateway Self.ID differs before restart gate' >&2; exit 1; }
systemctl --user restart woow-tailscale-gateway.service
scripts/verify.sh
node_after="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"
[[ "$node_after" == "$node_before" ]] || { echo 'gateway exact Self.ID changed at restart gate' >&2; exit 1; }
backup="${XDG_RUNTIME_DIR:-/tmp}/woow-gateway-pre-matter-removal-$(date -u +%Y%m%dT%H%M%SZ).tar"
scripts/backup.sh "$backup"

# Resolve and revalidate every exact Matter object only after all live gates.
podman container inspect matter-server >"$work/matter-container.json"
matter_name="$(jq -er '.[0].Name | ltrimstr("/")' "$work/matter-container.json")"
[[ "$matter_name" == matter-server ]] || { echo 'Matter container exact-name mismatch' >&2; exit 1; }
matter_id="$(jq -er '.[0].Id' "$work/matter-container.json")"
image_id="$(jq -er '.[0].Image' "$work/matter-container.json")"
[[ "$(jq '[.[0].Mounts[]? | select(.Name=="matter-server_data")]|length' "$work/matter-container.json")" == 1 ]] || { echo 'Matter volume is not mounted exactly once' >&2; exit 1; }
[[ "$(jq '[.[0].Mounts[]? | select(.Name=="matter-server_data" and .Type=="volume" and .Destination=="/data")]|length' "$work/matter-container.json")" == 1 ]] || { echo 'Matter volume identity/destination mismatch' >&2; exit 1; }
[[ "$(podman volume inspect matter-server_data | jq -er '.[0].Name')" == matter-server_data ]] || { echo 'Matter volume exact-name mismatch' >&2; exit 1; }
mapfile -t units < <(grep -lE '(^|[ =/])matter-server([[:space:]]|$)' "$HOME/.config/systemd/user"/*.service 2>/dev/null || true)
[[ ${#units[@]} == 1 && "${units[0]}" == "$HOME/.config/systemd/user/"* && -f "${units[0]}" && ! -L "${units[0]}" ]] || { echo 'expected exactly one canonical Matter user unit' >&2; exit 1; }
python3 - "${units[0]}" <<'PY'
import pathlib,shlex,sys
lines=[x for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.startswith('ExecStart=') and x!='ExecStart=']
if len(lines)!=1: raise SystemExit('Matter unit must have exactly one ExecStart')
words=shlex.split(lines[0][len('ExecStart='):])
if not words or pathlib.Path(words[0].lstrip('-:@+!')).name!='podman':
 raise SystemExit('Matter ExecStart executable is not Podman')
a=words[1:]
if not a or a[0]!='run': raise SystemExit('Matter ExecStart is not podman run')
def vals(long,short=None):
 out=[];i=0
 while i<len(a):
  x=a[i]
  if x==long or (short and x==short):
   i+=1
   if i>=len(a): raise SystemExit('Matter unit option has no value')
   out.append(a[i])
  elif x.startswith(long+'='): out.append(x.split('=',1)[1])
  elif short and x.startswith(short) and x!=short: out.append(x[len(short):])
  i+=1
 return out
if vals('--name') != ['matter-server']: raise SystemExit('Matter unit does not own exact container name')
volumes=vals('--volume','-v')
owned=[v for v in volumes if v.split(':',1)[0]=='matter-server_data']
if len(owned)!=1 or owned[0].split(':')[:2]!=['matter-server_data','/data']:
 raise SystemExit('Matter unit does not own one exact volume destination')
PY
matter_unit="$(basename "${units[0]}")"
fragment="$(systemctl --user show -p FragmentPath --value "$matter_unit")"
[[ "$fragment" == "${units[0]}" ]] || { echo 'loaded Matter unit path mismatch' >&2; exit 1; }

# No non-Matter container may share the immutable image or named volume.
for id in $(podman ps -aq); do
  [[ "$id" == "$matter_id" ]] && continue
  other="$(podman inspect "$id")"
  [[ "$(jq -r '.[0].Image' <<<"$other")" != "$image_id" ]] || { echo 'Matter image is shared' >&2; exit 1; }
  jq -e 'all(.[0].Mounts[]?; .Name != "matter-server_data")' >/dev/null <<<"$other" || { echo 'Matter volume is shared' >&2; exit 1; }
done
# This baseline is deliberately after the restart gate, because that gate may
# recreate the gateway container under the conventional systemd service.
snapshot_containers >"$work/before-mutation.json"

mutation_started=true
systemctl --user disable --now "$matter_unit"
rm -- "${units[0]}"
systemctl --user daemon-reload
podman rm matter-server >/dev/null
podman volume rm matter-server_data >/dev/null
podman image rm "$image_id" >/dev/null

scripts/verify.sh
! podman container inspect matter-server >/dev/null 2>&1
! podman volume inspect matter-server_data >/dev/null 2>&1
! podman image inspect "$image_id" >/dev/null 2>&1
[[ ! -e "${units[0]}" ]]
snapshot_containers >"$work/after-mutation.json"
python3 - "$work/before-mutation.json" "$work/after-mutation.json" <<'PY'
import json,sys
def normalized(path):
    result={}
    for item in json.load(open(path,encoding='utf-8')):
        if (item.get('Name') or '').lstrip('/')=='matter-server':
            continue
        state=item.get('State') or {}
        result[item['Id']]={
            'name':item.get('Name'),
            'running':state.get('Running'),
            'health':(state.get('Health') or {}).get('Status'),
        }
    return result
if normalized(sys.argv[1]) != normalized(sys.argv[2]):
    raise SystemExit('unrelated container state changed')
PY
mutation_started=false
echo "Matter Server permanently removed. Gateway backup retained at $backup"
