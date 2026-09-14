#!/usr/bin/env bash
# tests/host-tree.sh: pins what scripts/migrate-legacy.sh does on a host whose tailscale node
# is NOT the one this package installs.
#
# woowtechopenclaw runs `woow-tailscale-gateway`, built from a Containerfile and entrypoint.sh
# that diverged from this repo by ~170 lines and pinned by image ID, started by a unit that
# runs resource_ownership.py and apply-official-services.sh out of a non-git tree. Three
# things used to go wrong there:
#   1. the script died with "no container named woow-tailscale: nothing to migrate (on a fresh
#      host run scripts/install.sh)" - and running install.sh there would build and start a
#      SECOND node against the same tailnet identity
#   2. `--name[= ]woow-tailscale\b` matched `--name woow-tailscale-gateway` (a word boundary
#      sits before the "-"), so a name override made unit discovery adopt the gateway's unit,
#      which the swap then stops and disables
#   3. that unit's Exec*Pre/Post hooks and its drop-in are reproduced nowhere in quadlet/
#
# No container, no network, no user manager: each case has its own HOME and a podman stub.
#
#   tests/host-tree.sh [filter]
#
# Every case runs in its own subshell (own HOME, own PATH), so:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-host-tree.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
filter=${1:-}
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }

case_() {
  local name=$1
  shift
  if [[ -n $filter && $name != *"$filter"* ]]; then return 0; fi
  local out
  if out=$( ("$@") 2>&1); then
    npass=$((npass + 1))
    printf 'ok   %s\n' "$name"
  else
    nfail=$((nfail + 1))
    FAILED+=("$name")
    printf 'FAIL %s\n%s\n' "$name" "$out"
  fi
}

mk_home() {
  local h
  h=$(mktemp -d "$ROOT/home.XXXXXX")
  mkdir -p "$h/.config/systemd/user"
  printf '%s' "$h"
}
mk_unit() { printf '%s\n' "$3" >"$1/.config/systemd/user/$2"; }

# mk_podman <home> <name>...: a podman stub whose `ps -a --format {{.Names}}` lists <name>...
# and whose `container exists` is true for exactly those names.
mk_podman() {
  local h=$1 bin=$1/bin
  shift
  mkdir -p "$bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'names="%s"\n' "$*"
    cat <<'STUB'
case ${1:-} in
  ps) for n in $names; do printf '%s\n' "$n"; done ;;
  container) [[ ${2:-} == exists ]] || exit 0
    for n in $names; do [[ $n == "${3:-}" ]] && exit 0; done; exit 1 ;;
  inspect) printf '<no value>\n' ;;
esac
exit 0
STUB
  } >"$bin/podman"
  chmod +x "$bin/podman"
  printf '%s' "$bin"
}

load() {
  # shellcheck source=../scripts/lib/quadlet-lib.sh
  . "$REPO/scripts/lib/quadlet-lib.sh"
  # shellcheck source=../scripts/common.sh
  . "$REPO/scripts/common.sh"
}

# The live ExecStart of woowtechopenclaw's gateway unit, in shape.
GATEWAY_EXEC='ExecStart=/usr/bin/podman run --rm --name woow-tailscale-gateway --network host localhost/woow-tailscale-gateway:latest'

# ---- ts_legacy_units must not match woow-tailscale-gateway --------------------------------
#
# Each Exec form is pinned by its OWN case. A single case with several Exec lines is a no-op
# control: the two-line compose unit below stayed green while its `podman start woow-tailscale`
# line was undiscovered, because the `stop -t 10` line still matched. The regression hides
# until a unit has ONLY the broken form - which is exactly openclaw's shape.
#
# one_form <unit name> <single Exec line> <what it is> [expected output]
one_form() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" "$1" "$2"
  load
  eq "$(ts_legacy_units)" "${4-$1}" "$3"
}

t_legacy_units_start_only() {
  one_form container-woow-tailscale.service \
    'ExecStart=/usr/bin/podman start woow-tailscale' 'podman start <name>'
}

t_legacy_units_stop_only() {
  one_form container-woow-tailscale.service \
    'ExecStart=/usr/bin/podman stop woow-tailscale' 'podman stop <name>'
}

t_legacy_units_stop_timeout() {
  one_form container-woow-tailscale.service \
    'ExecStop=/usr/bin/podman stop -t 10 woow-tailscale' 'podman stop -t N <name>'
}

t_legacy_units_restart_only() {
  one_form ts-restart.service \
    'ExecStart=/usr/bin/podman restart woow-tailscale' 'podman restart <name>'
}

t_legacy_units_no_abspath() {
  one_form ts-bare.service \
    'ExecStart=podman start woow-tailscale' 'podman without /usr/bin/'
}

t_legacy_units_quoted_name() {
  one_form ts-quoted.service \
    'ExecStart=/usr/bin/podman start "woow-tailscale"' 'a double-quoted name'
}

t_legacy_units_single_quoted_name() {
  one_form ts-sq.service \
    "ExecStart=/usr/bin/podman stop 'woow-tailscale'" 'a single-quoted name'
}

t_legacy_units_run_name() {
  one_form ts-manual.service \
    'ExecStart=/usr/bin/podman run --rm --name woow-tailscale --network host localhost/woow-tailscale:latest' \
    'a hand-made podman run unit'
}

t_legacy_units_run_equals_name() {
  one_form ts-run-eq.service \
    'ExecStart=/usr/bin/podman run -d --name=woow-tailscale localhost/woow-tailscale:latest' \
    '--name=<name>'
}

# the negative, per form: the gateway must not be discovered by a bare start either
t_legacy_units_start_only_gateway() {
  one_form gw-start.service \
    'ExecStart=/usr/bin/podman start woow-tailscale-gateway' \
    'podman start woow-tailscale-gateway must not be discovered' ''
}

t_legacy_units_positive() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" container-woow-tailscale.service \
    'ExecStart=/usr/bin/podman start woow-tailscale
ExecStop=/usr/bin/podman stop -t 10 woow-tailscale'
  load
  eq "$(ts_legacy_units)" "container-woow-tailscale.service" "the compose-era unit"
}

# Verified against the real line: `grep -E -- '--name[= ]woow-tailscale\b'` MATCHES it.
t_legacy_units_rejects_gateway() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" woow-tailscale-gateway.service "$GATEWAY_EXEC"
  mk_unit "$HOME" gw-start.service 'ExecStart=/usr/bin/podman start woow-tailscale-gateway'
  load
  eq "$(ts_legacy_units)" "" "woow-tailscale-gateway must not be discovered as woow-tailscale"
}

# ---- ts_require_legacy_container ----------------------------------------------------------
t_require_container_fresh_host() {
  HOME=$(mk_home)
  export HOME
  local bin out rc=0
  bin=$(mk_podman "$HOME")
  PATH=$bin:$PATH
  export PATH
  load
  out=$( (ts_require_legacy_container) 2>&1) || rc=$?
  eq "$rc" 1 "nothing to migrate"
  has "$out" "no container named woow-tailscale: nothing to migrate" "the fresh-host message"
  has "$out" "run scripts/install.sh" "install.sh is still the right advice on a fresh host"
}

t_require_container_foreign_lineage() {
  HOME=$(mk_home)
  export HOME
  local bin out rc=0
  bin=$(mk_podman "$HOME" woow-tailscale-gateway)
  PATH=$bin:$PATH
  export PATH
  mk_unit "$HOME" woow-tailscale-gateway.service "$GATEWAY_EXEC"
  load
  out=$( (ts_require_legacy_container) 2>&1) || rc=$?
  eq "$rc" 1 "a foreign tailscale node must be refused"
  has "$out" "woow-tailscale-gateway" "the real container is named"
  has "$out" "different lineage" "the diagnosis"
  has "$out" "second tailscale node against the same tailnet identity" "why install.sh is wrong here"
  hasnt "$out" "on a fresh host run scripts/install.sh" "the dangerous suggestion must be gone"
}

t_require_container_present() {
  HOME=$(mk_home)
  export HOME
  local bin
  bin=$(mk_podman "$HOME" woow-tailscale woow-tailscale-gateway)
  PATH=$bin:$PATH
  export PATH
  load
  ts_require_legacy_container || die_t "must accept the container it adopts"
}

# ---- Exec hooks and drop-ins --------------------------------------------------------------
t_unit_hooks_read() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" woow-tailscale-gateway.service \
    "ExecStartPre=/usr/bin/python3 %h/tree/scripts/resource_ownership.py --claim
ExecStartPre=/usr/bin/podman network create --ignore gw
$GATEWAY_EXEC
ExecStopPost=/usr/bin/python3 %h/tree/scripts/resource_ownership.py --release"
  mkdir -p "$HOME/.config/systemd/user/woow-tailscale-gateway.service.d"
  printf 'ExecStartPost=%%h/tree/scripts/apply-official-services.sh\n' \
    >"$HOME/.config/systemd/user/woow-tailscale-gateway.service.d/official-services.conf"
  load
  local out
  out=$(ts_unit_hooks woow-tailscale-gateway.service)
  has "$out" "resource_ownership.py --claim" "ExecStartPre"
  has "$out" "resource_ownership.py --release" "ExecStopPost"
  has "$out" "drop-in=official-services.conf" "the drop-in directory"
  has "$out" "apply-official-services.sh" "the drop-in's ExecStartPost"
}

t_require_reproducible_units_refuses() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" woow-tailscale-gateway.service \
    "ExecStartPre=/usr/bin/python3 %h/tree/scripts/resource_ownership.py --claim
$GATEWAY_EXEC"
  load
  local out rc=0
  out=$( (ts_require_reproducible_units woow-tailscale-gateway.service) 2>&1) || rc=$?
  eq "$rc" 1 "a unit with hooks must be refused"
  has "$out" "hooks this package does not reproduce" "the diagnosis"
  has "$out" "resource_ownership.py --claim" "the hook is quoted"
}

t_require_reproducible_units_plain() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" container-woow-tailscale.service 'ExecStart=/usr/bin/podman start woow-tailscale'
  load
  ts_require_reproducible_units container-woow-tailscale.service \
    || die_t "a plain unit must pass"
  ts_require_reproducible_units || die_t "no units at all must pass"
}

# ---- lineage ------------------------------------------------------------------------------
t_lineage_accepts_this_repo() {
  load
  ql_require_own_lineage "$REPO" WOOWTECH/Woow_podman_vpn_tailscale_package \
    || die_t "this checkout must pass its own lineage check"
}

t_lineage_refuses_archived_host_tree() {
  load
  local arch=$REPO/archive/pre-quadlet-deployment/tree out rc=0
  [[ -f $arch/.deployed-commit ]] || die_t "fixture gone: $arch/.deployed-commit"
  out=$( (ql_require_own_lineage "$arch" WOOWTECH/Woow_podman_vpn_tailscale_package) 2>&1) || rc=$?
  eq "$rc" 1 "the archived host tree must be refused"
  has "$out" "pre-Quadlet deployment tree" "the diagnosis"
  has "$out" "do not delete this tree" "the do-not-delete warning"
}

t_script_run_from_host_tree() {
  HOME=$(mk_home)
  export HOME
  local tree=$HOME/Woow_podman_vpn_tailscale_package out rc=0
  mkdir -p "$tree/scripts/lib"
  printf '0123456789abcdef\n' >"$tree/.deployed-commit"
  printf '#!/usr/bin/env bash\necho deploy\n' >"$tree/scripts/deploy.sh"
  : >"$tree/scripts/lib/resource_ownership.py"
  cp "$REPO/scripts/migrate-legacy.sh" "$tree/scripts/migrate-legacy.sh"
  out=$( (bash "$tree/scripts/migrate-legacy.sh" --status) 2>&1) || rc=$?
  eq "$rc" 1 "migrate-legacy.sh must refuse to run out of the host tree"
  hasnt "$out" "No such file or directory" "the bare ENOENT must be gone"
  has "$out" "pre-Quadlet deployment tree" "the diagnosis"
}

case_ legacy-units-start-only t_legacy_units_start_only
case_ legacy-units-stop-only t_legacy_units_stop_only
case_ legacy-units-stop-timeout t_legacy_units_stop_timeout
case_ legacy-units-restart-only t_legacy_units_restart_only
case_ legacy-units-no-abspath t_legacy_units_no_abspath
case_ legacy-units-quoted-name t_legacy_units_quoted_name
case_ legacy-units-single-quoted-name t_legacy_units_single_quoted_name
case_ legacy-units-run-name t_legacy_units_run_name
case_ legacy-units-run-equals-name t_legacy_units_run_equals_name
case_ legacy-units-start-only-gateway t_legacy_units_start_only_gateway
case_ legacy-units-positive t_legacy_units_positive
case_ legacy-units-rejects-gateway t_legacy_units_rejects_gateway
case_ require-container-fresh-host t_require_container_fresh_host
case_ require-container-foreign-lineage t_require_container_foreign_lineage
case_ require-container-present t_require_container_present
case_ unit-hooks-read t_unit_hooks_read
case_ require-reproducible-units-refuses t_require_reproducible_units_refuses
case_ require-reproducible-units-plain t_require_reproducible_units_plain
case_ lineage-accepts-this-repo t_lineage_accepts_this_repo
case_ lineage-refuses-archived-host-tree t_lineage_refuses_archived_host_tree
case_ script-run-from-host-tree t_script_run_from_host_tree

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
