#!/usr/bin/env bash
# tests/rollback-model.sh: pins the rollback model that scripts/migrate-legacy.sh uses to keep
# the legacy containers available (STANDARD 7a). The three helpers it exercises -
# ts_legacy_capture, ts_legacy_retire and ts_legacy_restore, defined in scripts/common.sh -
# are the only code that decides between "rename and leave stopped" and "capture and remove",
# so pinning them pins the cutover and the rollback.
#
#   tests/rollback-model.sh [name-filter]
#
# podman and systemctl are the doubles in tests/shims, placed first on PATH; every test gets
# its own HOME and shim state. No container is created and the real user manager is never
# touched. Two host shapes are modelled:
#   toypark1234      podman-restart.service disabled -> rename, exactly as the seven live
#                    migrations behave today
#   woowtechopenclaw podman-restart.service enabled and a container with restart-policy
#                    `always` -> capture and remove, because a renamed copy would revive at
#                    the next boot and fight the new Quadlet container
#
# Every test runs in its own subshell on purpose (isolated HOME, shim state, env), so the
# "modified in a subshell" notes do not apply here:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ts-rollback-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
calls() { cat "$SHIM_STATE/calls"; }
ncalls() { grep -cF -- "$1" "$SHIM_STATE/calls" || true; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

# ---- fixtures ---------------------------------------------------------------------------
# mk_legacy <name> <policy>: the legacy node as a hand-written unit leaves it - a `podman run`
# with host networking, the identity bind-mounted at /var/lib/tailscale, and NO --restart on
# the command line (the policy, when there is one, lives on the container object only).
mk_legacy() {
  local name=$1 policy=$2 image=localhost/woow-tailscale-gateway:latest d
  d=$SHIM_STATE/containers/$name
  mkdir -p "$d" "$SHIM_STATE/image-ids"
  printf '%s' "$policy" >"$d/policy"
  printf '0' >"$d/retries"
  printf 'cid-%s' "$name" >"$d/id"
  printf '%s' "$image" >"$d/image"
  printf 'imgid-ts' >"$d/image_id"
  printf 'imgid-ts' >"$SHIM_STATE/image-ids/${image//[\/:@]/_}"
  printf 'host' >"$d/netmode"
  printf 'false' >"$d/autoremove"
  printf '' >"$d/project"
  printf '%s' "$name" >"$d/service"
  printf '4096' >"$d/sizerw"
  printf 'bind||/home/tester/.local/share/woow-tailscale/state|/var/lib/tailscale|true|rprivate\n' >"$d/mounts"
  : >"$d/networks"
  : >"$d/ports"
  : >"$d/labels"
  : >"$d/label"
  printf '%s\0' /usr/bin/podman run "--name=$name" -d --network host --cap-add NET_ADMIN \
    -v /home/tester/.local/share/woow-tailscale/state:/var/lib/tailscale \
    -e TS_HOSTNAME=woow-openclaw-services-1 \
    localhost/woow-tailscale-gateway:latest >"$d/createcommand.argv0"
}
# mk_api_created <name> <policy>: a container created through the podman API (docker-compose
# over the socket, podman play): its CreateCommand is empty, so nothing can be replayed.
mk_api_created() {
  mk_legacy "$1" "$2"
  : >"$SHIM_STATE/containers/$1/createcommand.argv0"
}
enable_restart_unit() { # what woowtechopenclaw looks like
  mkdir -p "$SHIM_STATE/units/podman-restart.service"
  echo enabled >"$SHIM_STATE/units/podman-restart.service/UnitFileState"
}

# ---- the toypark shape: rename, and nothing else ------------------------------------------
t_disabled_restart_unit_keeps_the_rename_path() {
  mk_legacy woow-tailscale unless-stopped
  eq "$(ql_rollback_strategy woow-tailscale 2>/dev/null)" rename "strategy on a toypark-like host"
  expect_ok ts_legacy_retire rename 20260914 "$T/bk" woow-tailscale
  has "$OUT" "renamed woow-tailscale -> woow-tailscale-legacy-20260914"
  eq "$(ncalls 'podman rename woow-tailscale woow-tailscale-legacy-20260914')" 1 "rename of woow-tailscale"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed on the rename path"
  eq "$(ncalls 'podman commit')" 0 "nothing is committed on the rename path"
  [[ ! -d $T/bk/legacy-container ]] || die_t "the rename path must not write a capture"
  podman container exists woow-tailscale-legacy-20260914 || die_t "the renamed container is missing"
  # and the rollback renames it straight back
  expect_ok ts_legacy_restore 20260914 "$T/bk" woow-tailscale
  has "$OUT" "renamed woow-tailscale-legacy-20260914 -> woow-tailscale"
  podman container exists woow-tailscale || die_t "the rollback did not bring woow-tailscale back"
  eq "$(ncalls 'podman create')" 0 "a renamed container is not recreated"
}

t_always_policy_with_a_disabled_unit_is_still_rename() {
  mk_legacy woow-tailscale always
  eq "$(ql_rollback_strategy woow-tailscale 2>/dev/null)" rename "a disabled unit never revives anything"
}

# ---- the openclaw shape: capture, then remove ---------------------------------------------
t_enabled_restart_unit_and_always_policy_takes_the_capture_path() {
  enable_restart_unit
  mk_legacy woow-tailscale always
  eq "$(ql_rollback_strategy woow-tailscale 2>/dev/null)" capture "strategy on an openclaw-like host"
  expect_ok ts_legacy_capture "$T/bk" woow-tailscale
  M=$T/bk/legacy-container/woow-tailscale/meta
  [[ -s $M ]] || die_t "no capture of woow-tailscale"
  eq "$(sed -n 's/^RECREATABLE=//p' "$M")" 1 "woow-tailscale is recreatable"
  eq "$(sed -n 's/^RESTART_POLICY=//p' "$M")" always "policy recorded"
  eq "$(sed -n 's/^NETWORK_MODE=//p' "$M")" host "host networking recorded"
  # the identity bind mount is what a rollback must find again; a plain podman rm keeps it
  grep -q '|/var/lib/tailscale|' "$T/bk/legacy-container/woow-tailscale/mounts" \
    || die_t "the state mount was not recorded"
  # capturing is read-only: the legacy stack is still up at this point
  eq "$(ncalls 'podman rm ')" 0 "the capture removes nothing"
  eq "$(ncalls 'podman rename')" 0 "the capture renames nothing"
  expect_ok ts_legacy_retire capture 20260914 "$T/bk" woow-tailscale
  has "$OUT" "removed woow-tailscale;"
  eq "$(ncalls 'podman rename')" 0 "the capture path must not rename"
  podman container exists woow-tailscale && die_t "woow-tailscale was not removed"
  podman container exists woow-tailscale-legacy-20260914 && die_t "the capture path must not leave a renamed copy"
  return 0
}

t_the_capture_path_never_removes_the_anonymous_volumes() {
  enable_restart_unit
  mk_legacy woow-tailscale always
  expect_ok ts_legacy_capture "$T/bk" woow-tailscale
  expect_ok ts_legacy_retire capture 20260914 "$T/bk" woow-tailscale
  hasnt "$(calls)" "podman rm -v" "rm -v would delete the anonymous volumes the capture expects back"
  hasnt "$(calls)" "podman rm --volumes" "rm --volumes would delete the anonymous volumes"
}

t_the_rollback_recreates_a_captured_container_with_its_policy() {
  enable_restart_unit
  mk_legacy woow-tailscale always
  expect_ok ts_legacy_capture "$T/bk" woow-tailscale
  expect_ok ts_legacy_retire capture 20260914 "$T/bk" woow-tailscale
  expect_ok ts_legacy_restore 20260914 "$T/bk" woow-tailscale
  has "$OUT" "recreated woow-tailscale"
  podman container exists woow-tailscale || die_t "the rollback did not recreate woow-tailscale"
  eq "$(ql_container_restart_policy woow-tailscale)" always "the original restart policy comes back"
}

t_capture_refuses_a_container_the_library_cannot_replay() {
  enable_restart_unit
  mk_api_created woow-tailscale always
  expect_fail ts_legacy_capture "$T/bk" woow-tailscale
  has "$OUT" "podman API"
  eq "$(ncalls 'podman rm ')" 0 "a refused capture removes nothing"
}

t_retire_refuses_to_remove_without_a_capture() {
  enable_restart_unit
  mk_legacy woow-tailscale always
  expect_fail ts_legacy_retire capture 20260914 "$T/bk" woow-tailscale
  has "$OUT" "no rollback copy of woow-tailscale"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed without a capture"
}

t_capture_is_idempotent_between_prepare_only_and_the_cutover() {
  enable_restart_unit
  mk_legacy woow-tailscale always
  expect_ok ts_legacy_capture "$T/bk" woow-tailscale # --prepare-only
  expect_ok ts_legacy_capture "$T/bk" woow-tailscale # the cutover reuses the same backup dir
  has "$OUT" "already in"
}

t_migrate_legacy_asks_the_host_before_it_renames() {
  # before this change the swap renamed unconditionally, with no guard at all
  grep -q 'ql_rollback_strategy' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "scripts/migrate-legacy.sh does not ask ql_rollback_strategy"
  # shellcheck disable=SC2016 # the literal text of the old line, not an expansion
  grep -qF 'podman rename "$TS_CONTAINER"' "$REPO/scripts/migrate-legacy.sh" \
    && die_t "the swap still renames the legacy container unconditionally"
  grep -q 'ts_legacy_retire' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "the swap does not go through ts_legacy_retire"
  grep -q 'ts_legacy_restore' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "the rollback does not go through ts_legacy_restore"
  return 0
}

t_the_capture_path_works_with_an_empty_suffix() {
  # the swap passes an empty suffix on the capture path (nothing is renamed there)
  # A capture-path cutover renames nothing, so it has no <name>-legacy-<suffix> to name and
  # passes an empty suffix. `${2:?}` would abort the script there; `${2-}` must not.
  enable_restart_unit
  mk_legacy woow-tailscale always
  expect_ok ts_legacy_capture "$T/bk" woow-tailscale
  expect_ok ts_legacy_retire capture "" "$T/bk" woow-tailscale
  podman container exists woow-tailscale && die_t "woow-tailscale was not removed"
  expect_ok ts_legacy_restore "" "$T/bk" woow-tailscale
  has "$OUT" "recreated woow-tailscale"
  eq "$(ql_container_restart_policy woow-tailscale)" always "the original restart policy comes back"
  # and with no capture either, the refusal names only what could exist
  expect_fail ts_legacy_restore "" "$T/empty" woow-tailscale
  hasnt "$OUT" "-legacy- " "an empty suffix must not be spelled into the message"
  return 0
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run" "$T/bk"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=rollback-model
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "the shims are not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/common.sh
    . "$REPO/scripts/common.sh"
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1))
    printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1))
    FAILED+=("$t")
    printf 'FAIL  %s\n' "$t"
    tail -n 25 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
