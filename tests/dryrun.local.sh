# shellcheck shell=bash
# tests/dryrun.local.sh: woow-tailscale assertions, sourced at the end of tests/dryrun.sh
# (the vendored template). The generic variants have already rendered their units into
# $WORK/<variant>/out. Uses $REPO, $WORK and the `failures` counter from tests/dryrun.sh.

_ts_gen() { # _ts_gen <variant> <unit>
  QUADLET_UNIT_DIRS="$WORK/$1/out" "${QL_QUADLET_BIN:-/usr/libexec/podman/quadlet}" -dryrun -user 2>/dev/null |
    awk -v want="---$2---" '$0 == want { on = 1; next } /^---.*---$/ { on = 0 } on'
}
_ts_ok=0
_ts_check() { # _ts_check <label> <command...>
  local label=$1
  shift
  if "$@"; then _ts_ok=$((_ts_ok + 1)); else echo "FAIL $label"; failures=$((failures + 1)); fi
}
_ts_has() { [[ $1 == *"$2"* ]]; }
_ts_hasnt() { [[ $1 != *"$2"* ]]; }
_ts_line() { grep -qxF -- "$2" <<<"$1"; }

for variant in example fixture-toypark1234; do
  unit=$(_ts_gen "$variant" woow-tailscale.service)
  exec_line=$(grep '^ExecStart=' <<<"$unit" || true)
  echo "== invariants: $variant"
  _ts_check "$variant: container name" _ts_has "$exec_line" '--name=woow-tailscale '
  _ts_check "$variant: host network" _ts_has "$exec_line" '--network=host'
  _ts_check "$variant: userspace mode forced" _ts_has "$exec_line" '--env TS_USERSPACE_NETWORKING=true'
  _ts_check "$variant: web UI forced to loopback" _ts_has "$exec_line" '--env TS_WEB_LISTEN=127.0.0.1:8088'
  _ts_check "$variant: env file without a dash" _ts_has "$exec_line" '--env-file %h/.config/woow-tailscale/tailscale.env'
  _ts_check "$variant: Pull=never" _ts_has "$exec_line" '--pull never'
  _ts_check "$variant: pinned image tag" grep -qE 'localhost/woow-tailscale:[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+ *$' <<<"$exec_line"
  _ts_check "$variant: health command" _ts_has "$exec_line" '--health-cmd'
  _ts_check "$variant: no capabilities" _ts_hasnt "$exec_line" '--cap-add'
  _ts_check "$variant: no devices" _ts_hasnt "$exec_line" '--device'
  _ts_check "$variant: no published ports (host network)" _ts_hasnt "$exec_line" '--publish'
  _ts_check "$variant: state dir guard" _ts_has "$unit" 'ExecStartPre=/usr/bin/test -d '
  _ts_check "$variant: restarts" _ts_line "$unit" 'Restart=always'
  _ts_check "$variant: no bridge network unit" [ ! -e "$WORK/$variant/out/woow-tailscale.network" ]
  case $variant in
    example) _ts_check "$variant: default state dir under %h" _ts_has "$exec_line" '-v %h/.local/share/woow-tailscale/state:/var/lib/tailscale' ;;
    fixture-toypark1234) _ts_check "$variant: adopted state dir" _ts_has "$exec_line" '-v %h/podman/woow-tailscale/state:/var/lib/tailscale' ;;
  esac
done
echo "invariants: $_ts_ok passed"

# The node env example is what podman reads with --env-file: it must survive the same lint
# as an installed file, and it must not carry the settings the unit forces.
_ts_envlint() { (QL_ENV_MODE_CHECK=0 ql_env_load "$1" >/dev/null 2>&1); }
_ts_check "node env example passes the env lint" _ts_envlint "$REPO/config/node/tailscale.env.example"
for k in TS_USERSPACE_NETWORKING TS_WEB_LISTEN BASIC_AUTH_USER CADDY_LAN_PORT; do
  _ts_check "node env example has no $k" _ts_hasnt "$(grep -v '^#' "$REPO/config/node/tailscale.env.example")" "$k="
done
_ts_check "web UI off by default in the example" grep -qx 'TS_WEB_UI=false' "$REPO/config/node/tailscale.env.example"
# shellcheck disable=SC2016 # literal shell defaults, matched as written in entrypoint.sh
_ts_check "entrypoint defaults the web UI to off" grep -q 'TS_WEB_UI="${TS_WEB_UI:-false}"' "$REPO/entrypoint.sh"
# shellcheck disable=SC2016
_ts_check "entrypoint defaults the web listener to loopback" grep -q 'TS_WEB_LISTEN="${TS_WEB_LISTEN:-127.0.0.1:8088}"' "$REPO/entrypoint.sh"
_ts_check "entrypoint refuses a non-loopback web listener" grep -q 'TS_WEB_ALLOW_NONLOCAL' "$REPO/entrypoint.sh"
_ts_check "the base image is pinned" grep -qE '^ARG BASE_IMAGE=docker.io/tailscale/tailscale:v[0-9]+\.[0-9]+\.[0-9]+$' "$REPO/Containerfile"
# The image tag and the pinned base must agree on the version.
_ts_base=$(sed -n 's/^ARG BASE_IMAGE=docker.io\/tailscale\/tailscale:v//p' "$REPO/Containerfile" | head -n1)
_ts_tag=$(sed -n 's/^Image=localhost\/woow-tailscale://p' "$REPO/quadlet/woow-tailscale.container" | head -n1)
_ts_check "image tag ${_ts_tag} matches the base ${_ts_base}" [ "${_ts_tag%-r*}" = "$_ts_base" ]
# The dropped bridge/Caddy design must not come back.
for f in compose.yml podman-tailscale.container podman-tailscale-proxy.container podman-tailscale.network examples/Caddyfile; do
  _ts_check "removed: $f" [ ! -e "$REPO/$f" ]
done
