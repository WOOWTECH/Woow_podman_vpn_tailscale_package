#!/usr/bin/env bash
# Restore official-Tailscale node Serve and Tailscale Services after container recreation.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONTAINER=woow-tailscale-gateway
CONFIG="$ROOT/systemd/official-services.json"
TAG=tag:woow-service-gateway

[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || { echo 'official service config is unavailable' >&2; exit 1; }
python3 - "$CONFIG" <<'PY'
import json,sys
value=json.load(open(sys.argv[1],encoding='utf-8'))
expected={'svc:od','svc:hermes','svc:odoo'}
if value.get('version')!='0.0.1' or set(value.get('services',{}))!=expected:
    raise SystemExit('official service config has unexpected service set')
for service in expected:
    if value['services'][service].get('endpoints')!={'tcp:443':'http://127.0.0.1:80'}:
        raise SystemExit('official service config has unexpected endpoint')
PY

running=false
for _ in {1..120}; do
  status="$(podman exec "$CONTAINER" tailscale status --json 2>/dev/null || true)"
  if jq -e --arg tag "$TAG" '.BackendState=="Running" and .Self.Online==true and ((.Self.Tags // [])|index($tag)!=null)' >/dev/null 2>&1 <<<"$status"; then
    running=true
    break
  fi
  sleep 1
done
[[ "$running" == true ]] || { echo 'official gateway did not become tagged and online' >&2; exit 1; }
prefs="$(podman exec "$CONTAINER" tailscale debug prefs)"
jq -e '.ControlURL=="https://controlplane.tailscale.com"' >/dev/null <<<"$prefs" || { echo 'gateway is not using the official Tailscale control plane' >&2; exit 1; }

# Dedicated Service DNS replaces legacy node-level application routes. Keep only
# the VPN-only NPM administration forward created by the container entrypoint.
podman exec "$CONTAINER" tailscale serve --https=443 off >/dev/null 2>&1 || true
podman exec "$CONTAINER" tailscale serve --tcp=18069 off >/dev/null 2>&1 || true
podman exec "$CONTAINER" tailscale serve --tcp=7456 off >/dev/null 2>&1 || true

# Service configuration is separate from machine state. Re-run the HTTPS CLI form
# on every start; set-config with tcp:443 alone loses the HTTPS termination intent.
for service in svc:od svc:hermes svc:odoo; do
  podman exec "$CONTAINER" tailscale serve --service="$service" --https=443 http://127.0.0.1:80 >/dev/null
  podman exec "$CONTAINER" tailscale serve advertise "$service" >/dev/null
done

serve="$(podman exec "$CONTAINER" tailscale serve status --json)"
jq -e '
  (.Services|keys|sort)==["svc:hermes","svc:od","svc:odoo"] and
  (.Web // {} | has("woow-openclaw-services-1.tailb7a69b.ts.net:443") | not) and
  .TCP["18081"].TCPForward=="127.0.0.1:18081" and
  (.TCP["18069"] // null)==null and
  (.TCP["7456"] // null)==null
' >/dev/null <<<"$serve" || { echo 'official Serve reconciliation did not converge' >&2; exit 1; }
echo 'Official Tailscale node and Service Serve configuration reconciled.'
