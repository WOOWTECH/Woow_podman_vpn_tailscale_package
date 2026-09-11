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

ts_wd_arm() {
  local unit=$1 delay=$2
  shift 2
  systemctl --user stop "$unit.timer" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1 || true
  systemd-run --user --unit="$unit" --on-active="$delay" --timer-property=AccuracySec=5s \
    --description="woow rollback watchdog" "$@" >/dev/null \
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
  systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  systemd-run --user --unit="$unit" --collect --description="woow migration step" "$@" >/dev/null \
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
