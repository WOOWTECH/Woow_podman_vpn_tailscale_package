#!/usr/bin/env bash
# Secure, idempotent rootless Headscale gateway enrollment and installation.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$ROOT" != *[$' \t\n']* ]] || { echo 'checkout path may not contain whitespace' >&2; exit 2; }
cd "$ROOT"
CONTAINER=woow-tailscale-gateway
VOLUME=woow-tailscale-gateway-state
IMAGE=localhost/woow-tailscale-gateway:latest
UNIT=woow-tailscale-gateway.service
RUNTIME="$ROOT/runtime"
INSTALL="$HOME/.config/woow-tailscale-gateway"
SYSTEMD="$HOME/.config/systemd/user"
LOCK="${XDG_RUNTIME_DIR:-$RUNTIME}/woow-tailscale-gateway.lock"
SELF_ID_FILE="$RUNTIME/gateway-self-id"; NODE_ID_FILE="$RUNTIME/gateway-node-id"; ENROLLMENT_ID_FILE="$RUNTIME/gateway-enrollment-id"
INVOCATION="$(python3 -c 'import uuid;print(uuid.uuid4())')"
mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
if [[ "${WOOW_GATEWAY_LOCK_HELD:-0}" != 1 ]]; then exec 9>"$LOCK"; flock -x 9; export WOOW_GATEWAY_LOCK_HELD=1; fi
for command in podman systemctl python3 jq curl timeout flock; do command -v "$command" >/dev/null || { echo "missing command: $command" >&2; exit 1; }; done
[[ -f .env.gateway && ! -L .env.gateway && "$(stat -c %a .env.gateway)" == 600 ]] || { echo '.env.gateway must be a mode-600 regular file' >&2; exit 1; }
python3 scripts/gateway_config.py render .env.gateway "$RUNTIME/gateway.env"
config="$(python3 scripts/gateway_config.py parse-env .env.gateway)"
HEADSCALE_CONTAINER="$(jq -r .HEADSCALE_CONTAINER <<<"$config")"; HOSTNAME="$(jq -r .GATEWAY_HOSTNAME <<<"$config")"
[[ "$(podman inspect -f '{{.State.Running}}' "$HEADSCALE_CONTAINER")" == true ]] || { echo 'Headscale container is not running' >&2; exit 1; }
version="$(podman exec "$HEADSCALE_CONTAINER" headscale version)"
[[ "$version" =~ (^|[[:space:]])v?0\.29\.3($|[[:space:]]) ]] || { echo 'Headscale must be exactly 0.29.3' >&2; exit 1; }
for port in 18081 18069; do timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" || { echo "host loopback port $port unavailable" >&2; exit 1; }; done
python3 scripts/resource_ownership.py check-container "$ROOT" --allow-absent
python3 scripts/resource_ownership.py check-volume "$ROOT" --allow-absent
service_active=false
if systemctl --user is-active --quiet "$UNIT"; then service_active=true; fi
unit_path="$SYSTEMD/$UNIT"
if [[ -e "$unit_path" || -L "$unit_path" ]]; then
  [[ -f "$unit_path" && ! -L "$unit_path" && "$(stat -c %u "$unit_path")" == "$(id -u)" && "$(stat -c %a "$unit_path")" == 600 ]] || { echo 'refusing to replace a foreign gateway unit' >&2; exit 1; }
  python3 scripts/gateway_unit.py check "$unit_path" systemd/woow-tailscale-gateway.service.in "$ROOT" >/dev/null || { echo 'refusing to replace a foreign gateway unit' >&2; exit 1; }
fi
if [[ "$service_active" == true ]]; then
  [[ -f "$unit_path" && ! -L "$unit_path" ]] || { echo 'refusing to replace an active foreign gateway unit' >&2; exit 1; }
  python3 scripts/resource_ownership.py check-container "$ROOT" || { echo 'active gateway service does not own the exact container' >&2; exit 1; }
fi
if podman image inspect "$IMAGE" >/dev/null 2>&1; then
  image_json="$(podman image inspect "$IMAGE")"
  jq -e --arg root "$ROOT" '.[0].Labels["org.woow-tailscale.project"]=="woow-tailscale-gateway" and .[0].Labels["org.woow-tailscale.role"]=="image" and .[0].Labels["org.woow-tailscale.managed-by"]=="woow-gateway-lifecycle" and .[0].Labels["org.woow-tailscale.checkout"]==$root' >/dev/null <<<"$image_json" || { echo 'refusing to replace a foreign gateway image tag' >&2; exit 1; }
fi

volume_new=false
if ! podman volume inspect "$VOLUME" >/dev/null 2>&1; then
  # Install the cleanup obligation before create so interruption cannot orphan it.
  volume_new=true
  podman volume create --label org.woow-tailscale.project=woow-tailscale-gateway --label org.woow-tailscale.role=state --label org.woow-tailscale.managed-by=woow-gateway-lifecycle --label "org.woow-tailscale.checkout=$ROOT" --label "org.woow-tailscale.invocation=$INVOCATION" "$VOLUME" >/dev/null
fi
podman build --format=docker --label org.woow-tailscale.project=woow-tailscale-gateway --label org.woow-tailscale.role=image --label org.woow-tailscale.managed-by=woow-gateway-lifecycle --label "org.woow-tailscale.checkout=$ROOT" -t "$IMAGE" -f Containerfile .
observed_image_id="$(podman image inspect "$IMAGE" --format '{{.Id}}')"
if ! built_image_id="$(python3 scripts/image_id.py "$observed_image_id")"; then
  echo 'built gateway image has no unambiguous full sha256 ID' >&2
  exit 1
fi
mkdir -p "$INSTALL" "$SYSTEMD"; chmod 700 "$INSTALL" "$SYSTEMD"
install -m 600 "$RUNTIME/gateway.env" "$INSTALL/.gateway.env.new"; mv -f "$INSTALL/.gateway.env.new" "$INSTALL/gateway.env"
rm -f -- "$SYSTEMD/.$UNIT.new"
python3 scripts/gateway_unit.py render systemd/woow-tailscale-gateway.service.in "$SYSTEMD/.$UNIT.new" "$ROOT" "$built_image_id"
mv -f "$SYSTEMD/.$UNIT.new" "$SYSTEMD/$UNIT"
systemctl --user daemon-reload
verify_running_image(){
  local running running_image observed_running_image
  running="$(podman container inspect "$CONTAINER")"
  observed_running_image="$(jq -er '.[0] | select(.State.Running==true) | .Image' <<<"$running")" || { echo 'running gateway container image does not match the deployed immutable image' >&2; return 1; }
  running_image="$(python3 scripts/image_id.py "$observed_running_image")" || { echo 'running gateway container has no unambiguous full sha256 image ID' >&2; return 1; }
  [[ "$running_image" == "$built_image_id" ]] || { echo 'running gateway container image does not match the deployed immutable image' >&2; return 1; }
}

# An exact-owned but empty state volume is equivalent to a newly created volume:
# it has no machine identity to protect and can safely recover by enrollment.
volume_mount="$(podman volume inspect --format '{{.Mountpoint}}' "$VOLUME")"
[[ -d "$volume_mount" && ! -L "$volume_mount" ]] || { echo 'gateway state volume mountpoint is unavailable' >&2; exit 1; }
volume_empty=false
if python3 - "$volume_mount" <<'PY'
import os,sys
raise SystemExit(0 if not any(os.scandir(sys.argv[1])) else 1)
PY
then volume_empty=true; fi
volume_was_empty="$volume_empty"
needs_enrollment=false
[[ "$volume_new" == true || "$volume_empty" == true ]] && needs_enrollment=true

# Existing nonempty machine state is reused without minting any key. Identity is
# checked before health so a Serve defect never causes credential creation.
if [[ "$needs_enrollment" == false ]]; then
  [[ -f "$SELF_ID_FILE" && ! -L "$SELF_ID_FILE" && "$(stat -c %a "$SELF_ID_FILE" 2>/dev/null)" == 600 ]] || { echo 'persistent volume has no protected Self.ID record; refusing re-enrollment' >&2; exit 1; }
  [[ -f "$NODE_ID_FILE" && ! -L "$NODE_ID_FILE" && "$(stat -c %a "$NODE_ID_FILE" 2>/dev/null)" == 600 ]] || { echo 'persistent volume has no protected Headscale node record; refusing re-enrollment' >&2; exit 1; }
  [[ -f "$ENROLLMENT_ID_FILE" && ! -L "$ENROLLMENT_ID_FILE" && "$(stat -c %a "$ENROLLMENT_ID_FILE" 2>/dev/null)" == 600 ]] || { echo 'persistent volume has no protected enrollment ID record' >&2; exit 1; }
  expected_self="$(<"$SELF_ID_FILE")"; expected_node="$(<"$NODE_ID_FILE")"
  if [[ "$service_active" == true ]]; then
    observed_current_image="$(podman container inspect --format '{{.Image}}' "$CONTAINER")"
    current_image="$(python3 scripts/image_id.py "$observed_current_image")" || { echo 'running gateway container has no unambiguous full sha256 image ID' >&2; exit 1; }
    if [[ "$current_image" != "$built_image_id" ]]; then systemctl --user restart "$UNIT"; else systemctl --user enable --now "$UNIT"; fi
  else
    systemctl --user enable --now "$UNIT"
  fi
  verify_running_image
  state_ok=false
  for _ in {1..45}; do
    status="$(podman exec "$CONTAINER" tailscale status --json 2>/dev/null || true)"
    if jq -e --arg host "$HOSTNAME" --arg self "$expected_self" '.BackendState=="Running" and .Self.ID==$self and ((.Self.HostName // .Self.DNSName // "" | rtrimstr("."))==$host)' >/dev/null 2>&1 <<<"$status"; then state_ok=true; break; fi
    sleep 2
  done
  if [[ "$state_ok" == true ]]; then
    self_ip="$(jq -er '.Self.TailscaleIPs[0]' <<<"$status")"
    nodes="$(mktemp "$RUNTIME/.nodes.XXXXXX")"; chmod 600 "$nodes"
    podman exec "$HEADSCALE_CONTAINER" headscale nodes list --output json >"$nodes"
    node_id="$(python3 scripts/headscale_json.py find-node "$nodes" "$HOSTNAME" --ip "$self_ip")"
    : >"$nodes"; rm -f "$nodes"
    [[ "$node_id" == "$expected_node" ]] || { systemctl --user stop "$UNIT" || true; echo 'Headscale node identity changed; refusing re-enrollment' >&2; exit 1; }
    if scripts/verify.sh; then
      echo 'Gateway deployed from persistent state; exact Self.ID reused and no enrollment key created.'
      exit 0
    fi
    systemctl --user stop "$UNIT" || true
    echo 'persistent gateway identity is valid but verification failed; refusing re-enrollment' >&2
    exit 1
  fi
  systemctl --user stop "$UNIT" || true
  echo 'persistent gateway identity does not match its exact Self.ID record; refusing re-enrollment' >&2
  exit 1
fi

response="$(mktemp "$RUNTIME/.preauth-response.XXXXXX")"; keyfile="$(mktemp "$RUNTIME/.enrollment.XXXXXX")"; idfile="$(mktemp "$RUNTIME/.preauth-id.XXXXXX")"; users="$(mktemp "$RUNTIME/.users.XXXXXX")"
chmod 600 "$response" "$keyfile" "$idfile" "$users"
key_created=false; enrollment_container_created=false; enrolled_node_id=''; steady_started=false; deployment_complete=false
cleanup() {
  rc=$?; trap - EXIT INT TERM; set +e
  if [[ "$steady_started" == true ]]; then systemctl --user stop "$UNIT" >/dev/null 2>&1 || rc=1; fi
  if [[ "$key_created" == true ]]; then
    ident=''
    if [[ -s "$idfile" ]]; then ident="$(<"$idfile")"; elif [[ -s "$response" ]]; then ident="$(jq -er '.id | select(type=="number")' "$response" 2>/dev/null)"; fi
    if [[ -n "$ident" ]]; then
      podman exec "$HEADSCALE_CONTAINER" headscale preauthkeys expire --id "$ident" >/dev/null 2>&1 || rc=1
      podman exec "$HEADSCALE_CONTAINER" headscale preauthkeys delete --id "$ident" >/dev/null 2>&1 || rc=1
      if podman exec "$HEADSCALE_CONTAINER" headscale preauthkeys list --output json >"$users" 2>/dev/null; then python3 scripts/headscale_json.py assert-preauth-id-absent "$users" "$ident" >/dev/null 2>&1 || rc=1; else rc=1; fi
    else
      echo 'CRITICAL: enrollment key creation was attempted but its identifier is unavailable for scoped cleanup' >&2; rc=1
    fi
  fi
  if [[ "$enrollment_container_created" == true ]]; then
    if python3 scripts/resource_ownership.py check-container "$ROOT" --enrollment-keyfile "$keyfile" --invocation "$INVOCATION" >/dev/null 2>&1; then
      if [[ -z "$enrolled_node_id" ]]; then
        cleanup_status="$(podman exec "$CONTAINER" tailscale status --json 2>/dev/null)"
        cleanup_ip="$(jq -r '.Self.TailscaleIPs[0] // empty' <<<"$cleanup_status" 2>/dev/null)"
        if [[ -n "$cleanup_ip" ]] && podman exec "$HEADSCALE_CONTAINER" headscale nodes list --output json >"$users" 2>/dev/null; then enrolled_node_id="$(python3 scripts/headscale_json.py find-node "$users" "$HOSTNAME" --ip "$cleanup_ip" 2>/dev/null)"; fi
      fi
      podman rm -f "$CONTAINER" >/dev/null 2>&1 || rc=1
    else rc=1; fi
    python3 scripts/resource_ownership.py assert-container-absent "$ROOT" >/dev/null 2>&1 || rc=1
  fi
  if [[ "$deployment_complete" == false && -n "$enrolled_node_id" ]]; then
    podman exec "$HEADSCALE_CONTAINER" headscale --force nodes delete --identifier "$enrolled_node_id" >/dev/null 2>&1 || rc=1
    if podman exec "$HEADSCALE_CONTAINER" headscale nodes list --output json >"$users" 2>/dev/null; then python3 scripts/headscale_json.py assert-node-id-absent "$users" "$enrolled_node_id" >/dev/null 2>&1 || rc=1; else rc=1; fi
  fi
  if [[ "$deployment_complete" == false && "$volume_was_empty" == true ]]; then
    for record in "$SELF_ID_FILE" "$NODE_ID_FILE" "$ENROLLMENT_ID_FILE"; do rm -f -- "$record" "$record.new" || rc=1; done
    if [[ "$volume_new" == true ]]; then
      volume_json="$(podman volume inspect "$VOLUME" 2>/dev/null)"
      if python3 scripts/resource_ownership.py check-volume "$ROOT" >/dev/null 2>&1 && jq -e --arg invocation "$INVOCATION" '.[0].Labels["org.woow-tailscale.invocation"]==$invocation' >/dev/null 2>&1 <<<"$volume_json"; then podman volume rm "$VOLUME" >/dev/null 2>&1 || rc=1; else rc=1; fi
      python3 scripts/resource_ownership.py assert-volume-absent "$ROOT" >/dev/null 2>&1 || rc=1
    else
      current_mount="$(podman volume inspect --format '{{.Mountpoint}}' "$VOLUME" 2>/dev/null)"
      if python3 scripts/resource_ownership.py check-volume "$ROOT" >/dev/null 2>&1 && [[ "$current_mount" == "$volume_mount" && -d "$current_mount" && ! -L "$current_mount" ]]; then
        python3 - "$current_mount" <<'PY' || rc=1
import os,shutil,sys
root=sys.argv[1]
for entry in os.scandir(root):
    if entry.is_dir(follow_symlinks=False): shutil.rmtree(entry.path)
    else: os.unlink(entry.path)
if any(os.scandir(root)): raise SystemExit('state volume cleanup did not return to empty')
PY
      else rc=1; fi
    fi
  fi
  for f in "$response" "$keyfile" "$idfile" "$users"; do [[ -e "$f" ]] && { : >"$f"; rm -f "$f"; }; done
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
podman exec "$HEADSCALE_CONTAINER" headscale users list --output json >"$users"
user_id="$(python3 scripts/headscale_json.py default-user-id "$users")"
# Install the scoped credential cleanup obligation before key creation.
key_created=true
podman exec "$HEADSCALE_CONTAINER" headscale preauthkeys create --user "$user_id" --reusable --expiration 5m --output json >"$response"
python3 scripts/headscale_json.py extract-preauth "$response" "$idfile" "$keyfile"
: >"$response"; rm -f "$response"
python3 scripts/resource_ownership.py reconcile-container "$ROOT"
# Install the cleanup obligation before run so interruption cannot orphan it.
enrollment_container_created=true
podman run -d --name "$CONTAINER" --network=host --env-file "$RUNTIME/gateway.env" --env TS_AUTHKEY_FILE=/run/secrets/headscale-preauth.key --volume "$VOLUME:/var/lib/tailscale" --volume "$keyfile:/run/secrets/headscale-preauth.key:ro" --label org.woow-tailscale.project=woow-tailscale-gateway --label org.woow-tailscale.role=gateway --label org.woow-tailscale.managed-by=woow-gateway-lifecycle --label "org.woow-tailscale.checkout=$ROOT" --label "org.woow-tailscale.invocation=$INVOCATION" "$built_image_id" >/dev/null
timeout 90 bash -c 'until podman exec woow-tailscale-gateway tailscale status --json | jq -e '\''.BackendState=="Running" and (.Self.ID|type=="string") and (.Self.TailscaleIPs[0]|type=="string")'\'' >/dev/null; do sleep 2; done'
enrolled_status="$(podman exec "$CONTAINER" tailscale status --json)"
self_id="$(jq -er '.Self.ID' <<<"$enrolled_status")"; self_ip="$(jq -er '.Self.TailscaleIPs[0]' <<<"$enrolled_status")"
podman exec "$HEADSCALE_CONTAINER" headscale nodes list --output json >"$users"
enrolled_node_id="$(python3 scripts/headscale_json.py find-node "$users" "$HOSTNAME" --ip "$self_ip")"
python3 scripts/resource_ownership.py check-container "$ROOT" --enrollment-keyfile "$keyfile" --invocation "$INVOCATION"
podman rm -f "$CONTAINER" >/dev/null
enrollment_container_created=false
python3 scripts/resource_ownership.py assert-container-absent "$ROOT"
ident="$(<"$idfile")"
expire_ok=true; delete_ok=true
podman exec "$HEADSCALE_CONTAINER" headscale preauthkeys expire --id "$ident" >/dev/null || expire_ok=false
podman exec "$HEADSCALE_CONTAINER" headscale preauthkeys delete --id "$ident" >/dev/null || delete_ok=false
: >"$keyfile"; rm -f "$keyfile"
podman exec "$HEADSCALE_CONTAINER" headscale preauthkeys list --output json >"$users"
python3 scripts/headscale_json.py assert-preauth-id-absent "$users" "$ident"
[[ "$expire_ok" == true ]] || { echo 'failed to expire enrollment key' >&2; exit 1; }
[[ "$delete_ok" == true ]] || { echo 'failed to delete enrollment key' >&2; exit 1; }
key_created=false
: >"$idfile"; rm -f "$idfile"
node_id="$enrolled_node_id"
printf '%s\n' "$ident" >"$ENROLLMENT_ID_FILE.new"; chmod 600 "$ENROLLMENT_ID_FILE.new"; mv -f "$ENROLLMENT_ID_FILE.new" "$ENROLLMENT_ID_FILE"
printf '%s\n' "$self_id" >"$SELF_ID_FILE.new"; chmod 600 "$SELF_ID_FILE.new"; mv -f "$SELF_ID_FILE.new" "$SELF_ID_FILE"
printf '%s\n' "$node_id" >"$NODE_ID_FILE.new"; chmod 600 "$NODE_ID_FILE.new"; mv -f "$NODE_ID_FILE.new" "$NODE_ID_FILE"
steady_started=true
systemctl --user enable --now "$UNIT"
verify_running_image
timeout 90 bash -c 'until podman healthcheck run woow-tailscale-gateway >/dev/null 2>&1; do sleep 2; done'
python3 scripts/resource_ownership.py check-container "$ROOT"
inspect="$(podman container inspect "$CONTAINER")"
jq -e '.[0] | .HostConfig.NetworkMode=="host" and ((.Config.Env // []) | all(startswith("TS_AUTHKEY")|not)) and ((.Mounts // []) | all((.Destination // "") | startswith("/run/secrets/") | not)) and ((.HostConfig.PortBindings // {})|length==0) and ((.HostConfig.CapAdd // [])|length==0) and ((.HostConfig.Devices // [])|length==0)' >/dev/null <<<"$inspect"
steady_status="$(podman exec "$CONTAINER" tailscale status --json)"
[[ "$(jq -er '.Self.ID' <<<"$steady_status")" == "$self_id" ]] || { echo 'gateway Self.ID changed between enrollment and steady state' >&2; exit 1; }
scripts/verify.sh
steady_started=false
deployment_complete=true
trap - EXIT INT TERM
: >"$users"; rm -f "$users"
echo "Gateway deployed with exact Self.ID preserved and enrollment credential revoked (Headscale node $node_id)."
