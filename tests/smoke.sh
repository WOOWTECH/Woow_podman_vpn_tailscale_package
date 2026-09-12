#!/usr/bin/env bash
# tests/smoke.sh: post-install checks for the woow-tailscale node on this host. Read-only
# apart from one `podman healthcheck run`. scripts/install.sh, upgrade.sh and
# migrate-legacy.sh run it after every (re)start.
#
#   tests/smoke.sh [--expect-ip IP] [--expect-id ID]
#
# Without arguments it compares the node identity with the one recorded at the last
# successful install (~/.local/state/woow-quadlet/woow-tailscale/identity). A node that
# has never logged in (BackendState=NeedsLogin, no record) is reported, not failed.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"

expect_ip='' expect_id=''
while (($#)); do
  case $1 in
    --expect-ip) expect_ip=${2:?}; shift ;;
    --expect-id) expect_id=${2:?}; shift ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
STATE=$HOME/.local/state/woow-quadlet/$TS_APP
INSTALLED=$HOME/.config/containers/systemd/woow-tailscale.container
web_ui=$(ts_env_value "$TS_NODE_ENV" TS_WEB_UI false)
udp_port=$(ts_env_value "$TS_NODE_ENV" TS_UDP_PORT 41641)
state_dir=$(ts_state_dir)
fails=0
pass() { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
note() { printf 'note  %s\n' "$*"; }

# 1. unit
if [[ $(systemctl --user is-active "$TS_UNIT" 2>/dev/null) == active ]]; then pass "$TS_UNIT is active"; else fail "$TS_UNIT is not active"; fi
frag=$(systemctl --user show -p FragmentPath --value "$TS_UNIT" 2>/dev/null)
if [[ $frag == */systemd/generator/* ]]; then pass "$TS_UNIT comes from the Quadlet generator"; else fail "$TS_UNIT is loaded from '$frag' (shadowed?)"; fi

# 2. container shape: host network, no capabilities, no devices, the configured state dir
shape=$(podman container inspect --format '{{.HostConfig.NetworkMode}} {{len .HostConfig.CapAdd}} {{len .HostConfig.Devices}}' "$TS_CONTAINER" 2>/dev/null || true)
read -r netmode caps devs <<<"${shape:-none 0 0}"
if [[ $netmode == host ]]; then pass "container is on the host network"; else fail "network mode is '${netmode:-?}', want host"; fi
if [[ ${caps:-0} == 0 && ${devs:-0} == 0 ]]; then pass "no added capabilities and no devices (userspace mode)"; else fail "container has $caps added capabilities and $devs devices"; fi
src=$(podman container inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tailscale"}}{{.Source}}{{end}}{{end}}' "$TS_CONTAINER" 2>/dev/null || true)
if [[ -n $state_dir && $src == "$state_dir" ]]; then pass "state directory is $state_dir"; else fail "state mount is '${src:-missing}', want $state_dir"; fi

# 3. health and backend state
if podman healthcheck run "$TS_CONTAINER" >/dev/null 2>&1; then pass "$TS_CONTAINER healthcheck passes"; else fail "$TS_CONTAINER healthcheck fails"; fi
read -r state id ip host <<<"$(ts_status "$TS_CONTAINER" | tr '\t' ' ')"
case ${state:-} in
  Running) pass "tailscaled is Running as ${host:-?} ($ip)" ;;
  NeedsLogin)
    if [[ -f $STATE/identity || -n $expect_ip$expect_id ]]; then fail "tailscaled reports NeedsLogin although this node was enrolled before"
    else note "tailscaled reports NeedsLogin: this node has not been logged in yet"; fi ;;
  *) fail "tailscaled reports '${state:-no state}'" ;;
esac

# 4. identity: the same node key and tailnet IP as before
want_ip=$expect_ip want_id=$expect_id
if [[ -z $want_ip$want_id && -f $STATE/identity ]]; then
  want_ip=$(sed -n 's/^tailnet_ip=//p' "$STATE/identity")
  want_id=$(sed -n 's/^node_id=//p' "$STATE/identity")
fi
if [[ -n $want_ip || -n $want_id ]]; then
  if [[ -n $want_ip ]]; then
    if [[ $ip == "$want_ip" ]]; then pass "tailnet IP is unchanged ($ip)"; else fail "tailnet IP is '${ip:-none}', expected $want_ip"; fi
  fi
  if [[ -n $want_id ]]; then
    if [[ $id == "$want_id" ]]; then pass "node id is unchanged"; else fail "node id is '${id:-none}', expected $want_id (the node re-registered)"; fi
  fi
else
  note "no recorded identity to compare with yet"
fi

# 5. the web UI never leaves loopback
listeners=$(ss -tlnH 2>/dev/null | awk '{print $4}' | sort -u)
if [[ $web_ui == true ]]; then
  if grep -qxF '127.0.0.1:8088' <<<"$listeners"; then pass "tailscale web listens on 127.0.0.1:8088"; else fail "TS_WEB_UI=true but nothing listens on 127.0.0.1:8088"; fi
fi
if grep -qE '^(\*|0\.0\.0\.0|\[::\]):8088$' <<<"$listeners"; then
  fail "port 8088 is exposed beyond loopback: that is a writable, unauthenticated node admin UI"
else
  pass "port 8088 is not exposed beyond loopback"
fi

# 6. WireGuard port
udp_listeners=$(ss -ulnH 2>/dev/null | awk '{print $4}' || true)
if grep -qE ":$udp_port\$" <<<"$udp_listeners"; then pass "UDP $udp_port is bound"; else fail "UDP $udp_port is not bound"; fi

# 7. the installed unit keeps the invariants
if [[ -f $INSTALLED ]]; then
  grep -qx 'Network=host' "$INSTALLED" || fail "the installed unit is not on the host network"
  grep -qx 'Environment=TS_USERSPACE_NETWORKING=true' "$INSTALLED" || fail "the installed unit does not force userspace networking"
  grep -qx 'Environment=TS_WEB_LISTEN=127.0.0.1:8088' "$INSTALLED" || fail "the installed unit does not force the loopback web UI"
  grep -qE '^Image=localhost/woow-tailscale:[0-9.]+-r[0-9]+$' "$INSTALLED" || fail "the installed unit does not pin an image tag"
  pass "installed unit invariants checked"
else
  fail "$INSTALLED is missing"
fi

if ((fails)); then
  echo "smoke: $fails check(s) failed"
  exit 1
fi
echo "smoke: PASS"
