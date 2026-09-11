# shellcheck shell=bash
# scripts/common.sh: helpers shared by the woow-tailscale scripts.
# Source it after scripts/lib/quadlet-lib.sh.

# shellcheck disable=SC2034 # read by the scripts that source this file
TS_APP=woow-tailscale
# shellcheck disable=SC2034
TS_CONTAINER=woow-tailscale
# shellcheck disable=SC2034
TS_UNIT=woow-tailscale.service
# shellcheck disable=SC2034
TS_INSTALL_ENV=$HOME/.config/woow-tailscale/woow-tailscale.env
# shellcheck disable=SC2034
TS_NODE_ENV=$HOME/.config/woow-tailscale/tailscale.env
# Settings the unit forces, or that belonged to the removed Caddy sidecar: never copied
# into the node env file by scripts/migrate-legacy.sh.
# shellcheck disable=SC2034
TS_DROP_KEYS='TS_USERSPACE_NETWORKING|TS_WEB_LISTEN|BASIC_AUTH_USER|BASIC_AUTH_HASH|CADDY_LAN_PORT|TAILSCALE_UPSTREAM|TINI_SUBREAPER'

# ts_env_value <file> <KEY> [default]: one value, without loading the file into QL_ENV
ts_env_value() {
  local v
  v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1)
  printf '%s' "${v:-${3:-}}"
}

# ts_state_dir: TS_STATE_DIR from the install env file, with %h expanded
ts_state_dir() { ql_expand_home "$(ts_env_value "$TS_INSTALL_ENV" TS_STATE_DIR)"; }

# ts_legacy_units: user units that start or stop a container named woow-tailscale
ts_legacy_units() {
  local d=$HOME/.config/systemd/user f
  [[ -d $d ]] || return 0
  for f in "$d"/*.service; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == "$TS_UNIT" ]] && continue
    if grep -qE '^[[:space:]]*Exec(Start|StartPre|Stop)=.*[[:space:]](start|stop|run|restart)[[:space:]].*\bwoow-tailscale\b' "$f" \
      || grep -qE '^[[:space:]]*Exec(Start|Stop)=.*[[:space:]]--name[= ]woow-tailscale\b' "$f"; then
      printf '%s\n' "${f##*/}"
    fi
  done
}

# ts_status <container>: BackendState, node ID, first tailnet IP and hostname, one line.
# jq lives in the image, so nothing is needed on the host.
ts_status() {
  podman exec "$1" sh -c 'tailscale status --json 2>/dev/null | jq -r "[.BackendState, (.Self.ID // \"-\"), (.Self.TailscaleIPs[0] // \"-\"), (.Self.HostName // \"-\")] | @tsv"' 2>/dev/null || true
}
ts_backend_state() { ts_status "$1" | cut -f1; }
ts_node_id() { ts_status "$1" | cut -f2; }
ts_node_ip() { ts_status "$1" | cut -f3; }
# ts_serve_hash <container>: sha256 of the serve configuration (never prints its content)
ts_serve_hash() {
  podman exec "$1" sh -c 'tailscale serve status --json 2>/dev/null || true' 2>/dev/null | sha256sum | cut -d' ' -f1
}
