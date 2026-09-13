#!/usr/bin/env bash
# Isolated userspace VPN client proof. Every object is invocation-labelled and trapped.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; cd "$ROOT"
RUNTIME="$ROOT/runtime"
if [[ "${WOOW_GATEWAY_LOCK_HELD:-0}" != 1 ]]; then exec 9>"${XDG_RUNTIME_DIR:-$RUNTIME}/woow-tailscale-gateway.lock"; flock -x 9; export WOOW_GATEWAY_LOCK_HELD=1; fi
scripts/verify.sh
uuid="$(python3 -c 'import uuid;print(uuid.uuid4())')"; prefix="woow-gateway-test-${uuid}"
net="$prefix-net"; volume="$prefix-state"; client="$prefix-client"
keyfile=''; response=''; idfile=''; data=''; pinglog=''
node_id=''; hs=''; cleanup_key_id=''; test_ip=''; key_creation_attempted=false
network_created=false; volume_created=false; client_created=false; probe_names=(); probe_count=0; baseline_node_ids=()
cleanup(){
  rc=$?; trap - EXIT INT TERM
  if [[ -z "$cleanup_key_id" && -n "$idfile" && -s "$idfile" ]]; then cleanup_key_id="$(<"$idfile")"; fi
  if [[ -z "$cleanup_key_id" && -n "$response" && -s "$response" ]]; then cleanup_key_id="$(jq -er '.id' "$response" 2>/dev/null || true)"; fi
  cleanup_rc=0; key_required=(); resource_args=(); probe_args=(); node_args=(); baseline_args=()
  [[ "$key_creation_attempted" == false ]] || key_required=(--key-required)
  [[ "$network_created" == false ]] || resource_args+=(--network "$net" --network-created)
  [[ "$volume_created" == false ]] || resource_args+=(--volume "$volume" --volume-created)
  [[ "$client_created" == false ]] || resource_args+=(--container "$client" --container-created)
  for probe in "${probe_names[@]}"; do probe_args+=(--probe "$probe"); done
  for baseline_id in "${baseline_node_ids[@]}"; do baseline_args+=(--baseline-node-id "$baseline_id"); done
  [[ "$key_creation_attempted" == false ]] || node_args=(--node-id "$node_id" --node-hostname "$prefix" --node-ip "$test_ip")
  python3 scripts/live_cleanup.py --headscale "${hs:-headscale}" --invocation "$uuid" "${resource_args[@]}" "${probe_args[@]}" "${baseline_args[@]}" --key-id "$cleanup_key_id" "${key_required[@]}" "${node_args[@]}" || cleanup_rc=$?
  for f in "$keyfile" "$response" "$idfile" "$data" "$pinglog"; do [[ -n "$f" && -e "$f" ]] && { : >"$f"; rm -f "$f"; }; done
  (( rc != 0 )) || rc=$cleanup_rc
  exit "$rc"
}
# Installed before the first temporary file or Podman resource is created.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
keyfile="$(mktemp "$RUNTIME/.live-enrollment.XXXXXX")"; response="$(mktemp "$RUNTIME/.live-response.XXXXXX")"; idfile="$(mktemp "$RUNTIME/.live-id.XXXXXX")"; data="$(mktemp "$RUNTIME/.live-json.XXXXXX")"; chmod 600 "$keyfile" "$response" "$idfile" "$data"
config="$(python3 scripts/gateway_config.py parse-env .env.gateway)"; hs="$(jq -r .HEADSCALE_CONTAINER <<<"$config")"; gateway_host="$(jq -r .GATEWAY_HOSTNAME <<<"$config")"; login="$(jq -r .HEADSCALE_URL <<<"$config")"
labels=(--label org.woow-tailscale.project=woow-tailscale-gateway --label org.woow-tailscale.role=live-test --label org.woow-tailscale.managed-by=woow-gateway-lifecycle --label "org.woow-tailscale.invocation=$uuid")
network_created=true
podman network create "${labels[@]}" "$net" >/dev/null
volume_created=true
podman volume create "${labels[@]}" "$volume" >/dev/null
podman exec "$hs" headscale nodes list --output json >"$data"
mapfile -t baseline_node_ids < <(jq -r '(if type=="array" then . else (.nodes // []) end)[]?.id | tostring' "$data")
podman exec "$hs" headscale users list --output json >"$data"; user="$(python3 scripts/headscale_json.py default-user-id "$data")"
key_creation_attempted=true
podman exec "$hs" headscale preauthkeys create --user "$user" --reusable --expiration 5m --output json >"$response"
python3 scripts/headscale_json.py extract-preauth "$response" "$idfile" "$keyfile"; : >"$response"; rm -f "$response"
image_id="$(podman image inspect localhost/woow-tailscale-gateway:latest --format '{{.Id}}')"
# Podman treats a relative bind source as a named volume. Reject anything except
# this checkout's canonical, non-symlinked, mode-600 runtime file.
python3 scripts/runtime_file.py "$RUNTIME" "$keyfile"
client_created=true
podman run -d --name "$client" --network "$net" --add-host host.containers.internal:host-gateway "${labels[@]}" --volume "$volume:/var/lib/tailscale" --volume "$keyfile:/run/secrets/live-preauth.key:ro" --entrypoint tailscaled "$image_id" --state=/var/lib/tailscale/tailscaled.state --socket=/tmp/tailscaled.sock --tun=userspace-networking --socks5-server=0.0.0.0:1055 >/dev/null
container_login="$(python3 - "$login" <<'PY'
import sys,urllib.parse
u=urllib.parse.urlsplit(sys.argv[1]);host='host.containers.internal'+((':'+str(u.port)) if u.port else '');print(urllib.parse.urlunsplit((u.scheme,host,'','','')))
PY
)"
podman exec "$client" tailscale --socket=/tmp/tailscaled.sock up --hostname "$prefix" --login-server "$container_login" --accept-dns=false --accept-routes=false --authkey=file:/run/secrets/live-preauth.key
for _ in {1..30}; do
  test_status="$(podman exec "$client" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null || echo '{}')"
  test_ip="$(jq -r '.Self.TailscaleIPs[0] // empty' <<<"$test_status")"
  podman exec "$hs" headscale nodes list --output json >"$data"
  if [[ -n "$test_ip" ]] && node_id="$(python3 scripts/headscale_json.py find-node "$data" "$prefix" --ip "$test_ip" 2>/dev/null)"; then break; fi
  node_id=''; sleep 2
 done
[[ -n "$node_id" ]] || { echo 'temporary Headscale node did not appear' >&2; exit 1; }
# Revoke the separate test key as soon as enrollment is complete.
ident="$(<"$idfile")"; cleanup_key_id="$ident"
podman exec "$hs" headscale preauthkeys expire --id "$ident" >/dev/null
podman exec "$hs" headscale preauthkeys delete --id "$ident" >/dev/null
podman exec "$hs" headscale preauthkeys list --output json >"$data"
python3 scripts/headscale_json.py assert-preauth-id-absent "$data" "$ident"
: >"$keyfile"; rm -f "$keyfile"; : >"$idfile"; rm -f "$idfile"
gateway_ip=''
for _ in {1..30}; do
  status="$(podman exec "$client" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null || echo '{}')"
  gateway_ip="$(jq -r --arg h "$gateway_host" '[.Peer[]? | select(((.HostName // .DNSName // "")|rtrimstr("."))==$h) | .TailscaleIPs[0]][0] // empty' <<<"$status")"
  [[ -z "$gateway_ip" ]] || break; sleep 2
 done
[[ -n "$gateway_ip" ]] || { echo 'gateway peer did not appear at the isolated client' >&2; exit 1; }
pinglog="$(mktemp "$RUNTIME/.live-ping.XXXXXX")"; chmod 600 "$pinglog"; direct=false
for _ in {1..30}; do if podman exec "$client" tailscale --socket=/tmp/tailscaled.sock ping --timeout=3s "$gateway_ip" >"$pinglog" 2>&1 && grep -Eq 'via [^ ]+:[0-9]+' "$pinglog" && ! grep -qi 'DERP' "$pinglog"; then direct=true; break; fi; sleep 2; done
: >"$pinglog"; rm -f "$pinglog"; [[ "$direct" == true ]] || { echo 'direct WireGuard ping not established' >&2; exit 1; }
podman exec "$client" tailscale --socket=/tmp/tailscaled.sock ping --peerapi --timeout=5s "$gateway_ip" >/dev/null
# The gateway image is the already-built immutable test toolchain. Containerfile
# explicitly installs curl, so no mutable or undeclared probe image is pulled.
curl_image="$image_id"
http_check(){
  local port="$1" code probe cleanup_rc=0
  probe_count=$((probe_count+1)); probe="$prefix-http-$probe_count"; probe_names+=("$probe")
  if ! code="$(podman run --name "$probe" --network "$net" "${labels[@]}" --entrypoint curl "$curl_image" -sS -o /dev/null --max-time 8 -w '%{http_code}' --proxy "socks5h://$client:1055" "http://$gateway_ip:$port/")"; then return 1; fi
  python3 scripts/live_cleanup.py --headscale "$hs" --invocation "$uuid" --probe "$probe" || cleanup_rc=$?
  (( cleanup_rc == 0 )) && [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
}
http_check 18081; http_check 18069
# Exact unit/container names and loopback bindings are proven before mutation.
python3 scripts/service_ownership.py
gateway_self_before="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"
[[ "$gateway_self_before" == "$(<runtime/gateway-self-id)" ]] || { echo 'gateway Self.ID differs before restart' >&2; exit 1; }
systemctl --user restart nginx-proxy-manager.service odoo18.service woow-tailscale-gateway.service
scripts/verify.sh
gateway_self_after="$(podman exec woow-tailscale-gateway tailscale status --json | jq -er '.Self.ID')"
[[ "$gateway_self_after" == "$gateway_self_before" ]] || { echo 'gateway Self.ID changed across restart' >&2; exit 1; }
python3 scripts/service_ownership.py
http_check 18081; http_check 18069
mkdir -p runtime; python3 - <<'PY'
import json
p='runtime/last-verification.json';d=json.load(open(p));d['live_test_status']='passed';open(p,'w').write(json.dumps(d,sort_keys=True)+'\n')
PY
trap - EXIT INT TERM; cleanup
