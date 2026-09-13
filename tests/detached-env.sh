#!/usr/bin/env bash
# tests/detached-env.sh: the transient units must carry the environment their half of the
# migration reads.
#
# `systemd-run --user` starts the unit from the USER MANAGER's environment, not from the
# calling shell: everything the detached half reads from the environment is dropped unless
# it is named with --setenv on the command line. Nothing asserted that, so
# QL_PATH_MOUNT_ALLOW - the documented allowlist of the shared library's mount guard - was
# silently inert during the only migration step that runs the guard (found in the live
# toypark1234 cutover, 2026-09-12: the swap unit warned although the forward was launched
# with QL_PATH_MOUNT_ALLOW=pi-web).
#
#   tests/detached-env.sh
#
# Creates nothing on the host except, where a systemd user manager is available, one
# transient `env` unit. podman, systemctl and systemd-run are stubbed for every check but
# that probe.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=../scripts/watchdog.sh
. "$REPO/scripts/watchdog.sh"

REAL_SYSTEMCTL=$(command -v systemctl || true)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/detached-env.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
note() { printf 'note  %s\n' "$*"; }

# ---- stubs: record what would have been run, touch nothing ---------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$TS_TEST_ARGV"
EOF
cat >"$WORK/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$WORK/bin/podman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/systemd-run" "$WORK/bin/systemctl" "$WORK/bin/podman"

# capture <argv-file> <function> <args...>: run one watchdog helper against the stubs
capture() {
  local out=$1
  shift
  : >"$out"
  (
    # shellcheck disable=SC2030 # deliberate: the stubs must not outlive this subshell,
    # so that the live probe at the end runs against the real systemd-run.
    export TS_TEST_ARGV=$out PATH=$WORK/bin:$PATH
    "$@"
  ) >/dev/null 2>&1
}
has_arg() { grep -qxF -- "$2" "$1"; }

# ---- 1. the two the migration cannot work without ------------------------------------------
# QL_PATH_MOUNT_ALLOW is read by ql_check_path_mounted inside install.sh, and install.sh
# only ever runs from the swap unit; WOOW_SSH_PATH_LOCK is the lock a detached rollback
# has to release. Asserted on the systemd-run command line itself, so this holds however
# the forwarding is implemented.
export QL_PATH_MOUNT_ALLOW=pi-web WOOW_SSH_PATH_LOCK=$WORK/ssh-path.lock
for helper in ts_run_detached ts_wd_arm; do
  argv=$WORK/argv-critical-$helper
  case $helper in
    ts_wd_arm) capture "$argv" ts_wd_arm woow-ts-test 15m /bin/true ;;
    *) capture "$argv" ts_run_detached woow-ts-test /bin/true ;;
  esac
  if [[ ! -s $argv ]]; then
    fail "$helper ran no systemd-run at all"
    continue
  fi
  for want in "--setenv=QL_PATH_MOUNT_ALLOW=pi-web" "--setenv=WOOW_SSH_PATH_LOCK=$WORK/ssh-path.lock"; do
    if has_arg "$argv" "$want"; then
      pass "$helper passes $want"
    else
      fail "$helper does not pass $want: the transient unit starts without it"
    fi
  done
done
unset QL_PATH_MOUNT_ALLOW WOOW_SSH_PATH_LOCK

# ---- 2. and everything else the swap path documents ----------------------------------------
if declare -p TS_DETACHED_ENV >/dev/null 2>&1 && ((${#TS_DETACHED_ENV[@]} > 0)); then
  pass "scripts/watchdog.sh declares TS_DETACHED_ENV (${#TS_DETACHED_ENV[@]} names)"
  for n in "${TS_DETACHED_ENV[@]}"; do export "$n=probe-$n"; done
  for helper in ts_run_detached ts_wd_arm; do
    argv=$WORK/argv-$helper
    case $helper in
      ts_wd_arm) capture "$argv" ts_wd_arm woow-ts-test 15m /bin/true ;;
      *) capture "$argv" ts_run_detached woow-ts-test /bin/true ;;
    esac
    missing=()
    for n in "${TS_DETACHED_ENV[@]}"; do
      has_arg "$argv" "--setenv=$n=probe-$n" || missing+=("$n")
    done
    if ((${#missing[@]} == 0)); then
      pass "$helper passes --setenv for all ${#TS_DETACHED_ENV[@]} declared names"
    else
      fail "$helper drops ${#missing[@]} of them: ${missing[*]}"
    fi
  done
  for n in "${TS_DETACHED_ENV[@]}"; do unset "$n"; done
else
  fail "scripts/watchdog.sh declares no TS_DETACHED_ENV: nothing says what a transient unit must carry"
fi

# ---- 3. a variable that is not set must not be injected as an empty one ---------------------
argv=$WORK/argv-unset
capture "$argv" ts_run_detached woow-ts-test /bin/true
if [[ ! -s $argv ]]; then
  fail "ts_run_detached ran no systemd-run at all"
elif grep -q -- '--setenv=[A-Za-z_][A-Za-z0-9_]*=$' "$argv"; then
  fail "an unset variable is passed as an empty --setenv=NAME= (that overrides nothing and hides a typo)"
else
  pass "unset variables are not passed at all"
fi

# ---- 4. migrate-legacy.sh --allow-broader reaches the guard ---------------------------------
mkdir -p "$WORK/home"
out=$(
  # shellcheck disable=SC2030,SC2031 # same: stubs and a throwaway HOME, subshell-scoped
  export PATH=$WORK/bin:$PATH HOME=$WORK/home
  bash "$REPO/scripts/migrate-legacy.sh" --allow-broader pi-web --allow-broader cloudflared --status 2>&1
)
rc=$?
if ((rc != 0)); then
  fail "migrate-legacy.sh --allow-broader NAME --status exited $rc: $(head -n1 <<<"$out")"
elif grep -q 'pi-web cloudflared' <<<"$out"; then
  pass "migrate-legacy.sh --allow-broader is repeatable and reported by --status"
else
  fail "migrate-legacy.sh --status does not report the mount-guard allowlist: $(tr '\n' ' ' <<<"$out")"
fi

# ---- 5. a real transient unit really receives it ---------------------------------------------
if [[ -n $REAL_SYSTEMCTL ]] && "$REAL_SYSTEMCTL" --user show -p Version >/dev/null 2>&1; then
  probe=$WORK/probe.env
  unit=woow-ts-envprobe-$$
  export QL_PATH_MOUNT_ALLOW=pi-web
  if (ts_run_detached "$unit" /bin/sh -c "/usr/bin/env >'$probe'") >/dev/null 2>&1; then
    ts_wait_unit "$unit" 30 >/dev/null 2>&1
    if grep -qx 'QL_PATH_MOUNT_ALLOW=pi-web' "$probe" 2>/dev/null; then
      pass "a real systemd-run --user unit receives QL_PATH_MOUNT_ALLOW"
    else
      fail "a real systemd-run --user unit did NOT receive QL_PATH_MOUNT_ALLOW (got '$(sed -n 's/^QL_PATH_MOUNT_ALLOW=/&/p' "$probe" 2>/dev/null)')"
    fi
  else
    note "skipped the live probe: systemd-run --user could not start $unit"
  fi
  unset QL_PATH_MOUNT_ALLOW
else
  note "skipped the live systemd-run --user probe: no systemd user manager on this machine"
fi

if ((fails)); then
  echo "detached-env: $fails check(s) failed"
  exit 1
fi
echo "detached-env: PASS"
