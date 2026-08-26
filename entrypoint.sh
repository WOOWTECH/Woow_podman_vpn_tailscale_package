#!/usr/bin/env bash
# Woow Tailscale entrypoint (podman edition).
#
# Reads env vars, launches tailscaled + tailscale up, optionally starts `tailscale web`.
# Env-var names mirror the HA add-on's option keys 1:1 so a HA user knows what to set.
set -euo pipefail

log() { printf '[woow-tailscale] %s\n' "$*" >&2; }

# --- Required / high-signal env ---------------------------------------------
TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-}"       # 空=官方 Tailscale，填 URL=Headscale
TS_AUTHKEY="${TS_AUTHKEY:-}"                 # tskey-auth-... (Tailscale) or pre-auth key (Headscale)
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"    # 節點在 tailnet 上的顯示名

# --- Feature toggles (default = HA add-on defaults) -------------------------
TS_ACCEPT_DNS="${TS_ACCEPT_DNS:-true}"
TS_ACCEPT_ROUTES="${TS_ACCEPT_ROUTES:-true}"
TS_ADVERTISE_EXIT_NODE="${TS_ADVERTISE_EXIT_NODE:-false}"
TS_ADVERTISE_CONNECTOR="${TS_ADVERTISE_CONNECTOR:-false}"
TS_ADVERTISE_ROUTES="${TS_ADVERTISE_ROUTES:-}"          # CSV, ex: 192.168.2.0/24,10.0.0.0/24
TS_ALWAYS_USE_DERP="${TS_ALWAYS_USE_DERP:-false}"
TS_SNAT_SUBNET_ROUTES="${TS_SNAT_SUBNET_ROUTES:-true}"
TS_STATEFUL_FILTERING="${TS_STATEFUL_FILTERING:-false}"
TS_TAGS="${TS_TAGS:-}"                                   # CSV, ex: tag:server,tag:woow
TS_EXIT_NODE="${TS_EXIT_NODE:-}"                         # tailnet IP or magicdns of exit-node peer
TS_USERSPACE_NETWORKING="${TS_USERSPACE_NETWORKING:-false}"  # true=userspace tun (no NET_ADMIN)
TS_UDP_PORT="${TS_UDP_PORT:-41641}"
TS_LOG_LEVEL="${TS_LOG_LEVEL:-info}"                     # trace|debug|info|notice|warning|error|fatal

# --- Web UI toggle -----------------------------------------------------------
# TS_WEB_UI=true  → 開啟 tailscale web --listen 0.0.0.0:8088 (預設用 reverse-proxy 加 basic auth 才 LAN 曝露)
TS_WEB_UI="${TS_WEB_UI:-true}"
TS_WEB_LISTEN="${TS_WEB_LISTEN:-0.0.0.0:8088}"

# --- Extra passthrough -------------------------------------------------------
TS_EXTRA_UP_ARGS="${TS_EXTRA_UP_ARGS:-}"                 # 任意額外 `tailscale up` 參數
TS_EXTRA_TAILSCALED_ARGS="${TS_EXTRA_TAILSCALED_ARGS:-}" # 任意額外 tailscaled 參數

# --- State dir ---------------------------------------------------------------
STATE_DIR="${STATE_DIR:-/var/lib/tailscale}"
mkdir -p "$STATE_DIR"

# ============================================================================
# 1. Start tailscaled
# ============================================================================
tailscaled_args=(
  --statedir="$STATE_DIR"
  --state="$STATE_DIR/tailscaled.state"
  --socket=/var/run/tailscale/tailscaled.sock
  --port="$TS_UDP_PORT"
)

if [[ "$TS_USERSPACE_NETWORKING" == "true" ]]; then
  tailscaled_args+=(--tun=userspace-networking)
  log "userspace networking enabled (no NET_ADMIN required, subnet-router/exit-node still work but slower)"
fi

if [[ "$TS_ALWAYS_USE_DERP" == "true" ]]; then
  export TS_DEBUG_ALWAYS_USE_DERP=true
  log "TS_DEBUG_ALWAYS_USE_DERP=true — all traffic routed via DERP"
fi

# Passthrough for advanced users
if [[ -n "$TS_EXTRA_TAILSCALED_ARGS" ]]; then
  # shellcheck disable=SC2206
  extra=($TS_EXTRA_TAILSCALED_ARGS)
  tailscaled_args+=("${extra[@]}")
fi

mkdir -p /var/run/tailscale
log "launching tailscaled with: ${tailscaled_args[*]}"
tailscaled "${tailscaled_args[@]}" &
TAILSCALED_PID=$!

# Wait for socket ready
for i in {1..30}; do
  [[ -S /var/run/tailscale/tailscaled.sock ]] && break
  sleep 0.5
done
if ! [[ -S /var/run/tailscale/tailscaled.sock ]]; then
  log "ERROR: tailscaled socket did not appear within 15s"
  kill "$TAILSCALED_PID" 2>/dev/null || true
  exit 1
fi

# ============================================================================
# 2. login_server migration (mirror HA reconcile-login-server logic)
# ============================================================================
# If TS_LOGIN_SERVER differs from current session, force logout to re-register.
CURRENT_LOGIN_URL="$(tailscale status --json 2>/dev/null | jq -r '.CurrentTailnet.MagicDNSSuffix // empty' || true)"
STATE_LOGIN="$STATE_DIR/.last_login_server"
if [[ -f "$STATE_LOGIN" ]]; then
  PREV_LOGIN="$(cat "$STATE_LOGIN")"
else
  PREV_LOGIN=""
fi
if [[ -n "$PREV_LOGIN" && "$PREV_LOGIN" != "$TS_LOGIN_SERVER" ]]; then
  log "login_server changed ($PREV_LOGIN → ${TS_LOGIN_SERVER:-<official>}); logging out to re-register"
  tailscale logout || true
fi
echo -n "$TS_LOGIN_SERVER" > "$STATE_LOGIN"

# ============================================================================
# 3. tailscale up (idempotent — safe to call every boot)
# ============================================================================
up_args=(
  --hostname="$TS_HOSTNAME"
  --accept-dns="$TS_ACCEPT_DNS"
  --accept-routes="$TS_ACCEPT_ROUTES"
  --snat-subnet-routes="$TS_SNAT_SUBNET_ROUTES"
  --stateful-filtering="$TS_STATEFUL_FILTERING"
  --advertise-exit-node="$TS_ADVERTISE_EXIT_NODE"
  --advertise-connector="$TS_ADVERTISE_CONNECTOR"
)

[[ -n "$TS_LOGIN_SERVER" ]]     && up_args+=(--login-server="$TS_LOGIN_SERVER")
[[ -n "$TS_AUTHKEY" ]]          && up_args+=(--authkey="$TS_AUTHKEY")
[[ -n "$TS_ADVERTISE_ROUTES" ]] && up_args+=(--advertise-routes="$TS_ADVERTISE_ROUTES")
[[ -n "$TS_EXIT_NODE" ]]        && up_args+=(--exit-node="$TS_EXIT_NODE")
[[ -n "$TS_TAGS" ]]             && up_args+=(--advertise-tags="$TS_TAGS")

if [[ -n "$TS_EXTRA_UP_ARGS" ]]; then
  # shellcheck disable=SC2206
  extra=($TS_EXTRA_UP_ARGS)
  up_args+=("${extra[@]}")
fi

log "running: tailscale up ${up_args[*]//--authkey=*/--authkey=***}"
if [[ -n "$TS_AUTHKEY" ]]; then
  # Non-interactive: authkey means `tailscale up` completes on its own.
  if ! tailscale up "${up_args[@]}"; then
    log "WARN: tailscale up failed with authkey. Check log above."
  fi
else
  # Interactive: `tailscale up` (no --authkey) BLOCKS waiting for the operator
  # to click the login URL. Backgrounding it so `tailscale web` can still start
  # and stream logs (login URL) come through. The user completes login via URL
  # (printed in log) or from the web UI.
  log "no TS_AUTHKEY set → backgrounding tailscale up (interactive login via URL / web UI)"
  tailscale up "${up_args[@]}" &
fi

# ============================================================================
# 4. Optional web UI on :8088
# ============================================================================
if [[ "$TS_WEB_UI" == "true" ]]; then
  # Small delay so tailscaled's localapi is definitely ready before `tailscale web` connects.
  sleep 1
  log "starting tailscale web on $TS_WEB_LISTEN (put a reverse-proxy with basic-auth in front!)"
  tailscale web --listen "$TS_WEB_LISTEN" --readonly=false &
fi

# ============================================================================
# 5. Wait on tailscaled (PID 1 via tini)
# ============================================================================
wait "$TAILSCALED_PID"
