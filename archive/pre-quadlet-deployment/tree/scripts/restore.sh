#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; cd "$ROOT"
[[ $# == 2 && "$2" == --confirm-restore ]] || { echo "usage: $0 ABSOLUTE-ARCHIVE --confirm-restore" >&2; exit 2; }
archive="$1"; [[ "$archive" == /* && -f "$archive" && ! -L "$archive" ]] || { echo 'archive must be an absolute regular file' >&2; exit 2; }
if [[ "${WOOW_GATEWAY_LOCK_HELD:-0}" != 1 ]]; then exec 9>"${XDG_RUNTIME_DIR:-$ROOT/runtime}/woow-tailscale-gateway.lock"; flock -x 9; export WOOW_GATEWAY_LOCK_HELD=1; fi
python3 scripts/resource_ownership.py check-container "$ROOT"
python3 scripts/resource_ownership.py check-volume "$ROOT"
stage="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/woow-gateway-restore.XXXXXX")"; chmod 700 "$stage"
rollback=''; rollback_retained=false; mutated=false; prior_identity=''
recreate_volume(){
 podman volume rm woow-tailscale-gateway-state >/dev/null &&
 podman volume create --label org.woow-tailscale.project=woow-tailscale-gateway --label org.woow-tailscale.role=state --label org.woow-tailscale.managed-by=woow-gateway-lifecycle --label "org.woow-tailscale.checkout=$ROOT" woow-tailscale-gateway-state >/dev/null
}
finish(){
 rc=$?; trap - EXIT INT TERM
 if [[ "$mutated" == true ]]; then
  systemctl --user stop woow-tailscale-gateway.service >/dev/null 2>&1 || true
  rollback_identity=''
  if recreate_volume && podman volume import woow-tailscale-gateway-state "$rollback" >/dev/null && systemctl --user start woow-tailscale-gateway.service && scripts/verify.sh >/dev/null && rollback_identity="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')" && [[ "$rollback_identity" == "$prior_identity" ]]; then
   echo 'Restore failed; prior state and exact Self.ID were rolled back and verified.' >&2
  else
   rollback_retained=true
   echo "CRITICAL: rollback verification failed; protected rollback archive retained at $rollback" >&2
  fi
 fi
 rm -rf "$stage"
 if [[ -n "$rollback" && "$rollback_retained" == false ]]; then rm -f "$rollback"; fi
 exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$archive" "$stage" <<'PY'
import os,stat,sys,tarfile
archive,dest=sys.argv[1:]
# Open the operator-selected path once without following a last-moment symlink.
# All validation and reads then use this descriptor, so replacing the pathname
# cannot swap in different bytes between the gate and extraction.
flags=os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)
fd=os.open(archive,flags)
try:
 info=os.fstat(fd)
 if not stat.S_ISREG(info.st_mode): raise SystemExit('archive is no longer a regular file')
 with os.fdopen(fd,'rb',closefd=False) as source, tarfile.open(fileobj=source,mode='r:*') as t:
  members=t.getmembers(); names=[m.name for m in members]
  if sorted(names)!=['SHA256SUMS','manifest.json','state.tar']: raise SystemExit('unexpected archive members')
  for m in members:
   if not m.isfile() or m.issym() or m.islnk() or os.path.isabs(m.name) or '..' in m.name.split('/'): raise SystemExit('unsafe archive member')
  for m in members:
   payload=t.extractfile(m)
   if payload is None: raise SystemExit('unsafe archive member')
   target=os.path.join(dest,m.name)
   out=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)
   with os.fdopen(out,'wb') as sink:
    while True:
     block=payload.read(1024*1024)
     if not block: break
     sink.write(block)
finally:
 os.close(fd)
PY
python3 - "$stage/SHA256SUMS" <<'PY'
import re,sys
lines=open(sys.argv[1],encoding='ascii').read().splitlines();seen=[]
for line in lines:
 m=re.fullmatch(r'([0-9a-f]{64})  (manifest\.json|state\.tar)',line)
 if not m: raise SystemExit('invalid checksum manifest')
 seen.append(m.group(2))
if sorted(seen)!=['manifest.json','state.tar']: raise SystemExit('checksum manifest must name each payload exactly once')
PY
(cd "$stage" && sha256sum --strict -c SHA256SUMS)
jq -e --arg root "$ROOT" '.schema==2 and .checkout==$root and .volume=="woow-tailscale-gateway-state" and (.self_id|type=="string" and length>0) and (.volume_labels["org.woow-tailscale.project"]=="woow-tailscale-gateway") and (.volume_labels["org.woow-tailscale.role"]=="state") and (.volume_labels["org.woow-tailscale.managed-by"]=="woow-gateway-lifecycle") and (.volume_labels["org.woow-tailscale.checkout"]==$root)' "$stage/manifest.json" >/dev/null
expected="$(jq -er .self_id "$stage/manifest.json")"
rollback="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/woow-gateway-rollback.XXXXXX.tar")"; chmod 600 "$rollback"
systemctl --user is-active --quiet woow-tailscale-gateway.service || { echo 'gateway service must be active' >&2; exit 1; }
prior_identity="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"
[[ "$prior_identity" == "$(<runtime/gateway-self-id)" ]] || { echo 'current gateway Self.ID differs from persisted identity' >&2; exit 1; }
podman volume export --output "$rollback" woow-tailscale-gateway-state
systemctl --user stop woow-tailscale-gateway.service
mutated=true
recreate_volume
podman volume import woow-tailscale-gateway-state "$stage/state.tar"
systemctl --user start woow-tailscale-gateway.service
scripts/verify.sh >/dev/null
actual="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"
[[ "$actual" == "$expected" && "$actual" == "$(<runtime/gateway-self-id)" ]] || { echo 'restored gateway exact Self.ID does not match manifest and persisted identity' >&2; exit 1; }
mutated=false; trap - EXIT INT TERM; rm -rf "$stage"; rm -f "$rollback"
echo 'Gateway state restored and exact Self.ID verified.'
