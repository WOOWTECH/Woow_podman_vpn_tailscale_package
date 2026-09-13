# shellcheck shell=bash
# scripts/watchdog.sh: dead-man timers for changes to a node that may be a management path.
# A transient systemd --user timer runs a rollback after N unless the operator commits, so
# an SSH session that dies mid-change cannot leave the host unreachable. Source it after
# scripts/lib/quadlet-lib.sh.
#
#   ts_wd_arm <unit> <delay> <command...>   arm (replacing any earlier timer of that name)
#   ts_wd_disarm <unit>                     stop and forget the timer
#   ts_wd_state <unit>                      "armed" or "off"
#   ts_run_detached <unit> <command...>     run a command as a transient unit, so that
#                                           losing the terminal cannot interrupt it
#   ts_wait_unit <unit> <timeout>           wait for such a unit to finish; returns its result

# Every variable a transient unit needs, spelled out. `systemd-run --user` starts the unit
# from the USER MANAGER's environment, never from this shell, so a variable that is not
# listed here does not exist inside the swap, inside the watchdog, or inside the
# scripts/install.sh they run - however carefully the operator exported it. That is how
# QL_PATH_MOUNT_ALLOW came to be inert in the one migration step that runs the mount guard.
# QL_DRY_RUN is deliberately absent: a transient unit is never a rehearsal, and the forward
# path exits before it detaches anything.
TS_DETACHED_ENV=(
  QL_PATH_MOUNT_ALLOW                        # ql_check_path_mounted's broader-mount allowlist
  WOOW_SSH_PATH_LOCK                         # the lock a detached rollback has to release
  QL_QUADLET_BIN QL_QUADLET_DIR              # where the library reads and writes units,
  QL_SYSTEMD_USER_DIR QL_CONFIG_ROOT         # config and manifests: the detached half must
  QL_STATE_ROOT                              # act on the same tree the caller prepared
  QL_LINGER_DIR QL_USER_GENERATOR            # preflight and shadow-unit guard overrides
  QL_SHADOW_DIRS QL_ALLOW_NO_LINGER
  QL_HOLD_UNITS QL_ENV_MODE_CHECK            # apply/env-lint behaviour
  QL_POLL_INTERVAL QL_WAIT_STABLE_S          # wait tuning
)

# ts_detached_setenv: fill TS_SETENV with --setenv=NAME=VALUE for every TS_DETACHED_ENV
# name that is set. A name that is not set is skipped rather than passed bare:
# `--setenv=NAME` alone defines NAME= (empty) inside the unit, which overrides nothing and
# hides a typo.
TS_SETENV=()
ts_detached_setenv() {
  local n
  TS_SETENV=()
  for n in "${TS_DETACHED_ENV[@]}"; do
    [[ -v $n ]] || continue
    TS_SETENV+=("--setenv=$n=${!n}")
  done
}

ts_wd_arm() {
  local unit=$1 delay=$2
  shift 2
  ts_detached_setenv
  systemctl --user stop "$unit.timer" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1 || true
  systemd-run --user --unit="$unit" --on-active="$delay" --timer-property=AccuracySec=5s \
    --description="woow rollback watchdog" "${TS_SETENV[@]}" "$@" >/dev/null \
    || ql_die "could not arm the watchdog timer $unit.timer"
  ql_info "watchdog armed: $unit.timer fires in $delay unless you commit"
}
ts_wd_disarm() {
  local unit=$1
  systemctl --user stop "$unit.timer" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1 || true
}
ts_wd_state() {
  if systemctl --user is-active --quiet "$1.timer" 2>/dev/null; then echo armed; else echo off; fi
}
ts_run_detached() {
  local unit=$1
  shift
  ts_detached_setenv
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  systemd-run --user --unit="$unit" --collect --description="woow migration step" \
    "${TS_SETENV[@]}" "$@" >/dev/null \
    || ql_die "could not start the transient unit $unit.service"
}
ts_wait_unit() {
  local unit=$1 timeout=${2:-600}
  local deadline=$((SECONDS + timeout))
  while systemctl --user is-active --quiet "$unit.service" 2>/dev/null; do
    ((SECONDS < deadline)) || { ql_warn "$unit.service is still running after ${timeout}s"; return 2; }
    sleep "${QL_POLL_INTERVAL:-2}"
  done
  local rc
  rc=$(systemctl --user show -p ExecMainStatus --value "$unit.service" 2>/dev/null || echo '')
  [[ ${rc:-1} == 0 ]]
}
