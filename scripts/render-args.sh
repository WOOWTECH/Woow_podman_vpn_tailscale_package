# shellcheck shell=bash
# scripts/render-args.sh: validation (and any computed values) for the rendered unit.
# Sourced by scripts/install.sh and tests/dryrun.sh, so CI checks what a host gets.
# render_args <envfile>: QL_ENV is loaded; sets RENDER_ARGS=(KEY=VALUE...).
render_args() {
  local dir
  dir=$(ql_env_get TS_STATE_DIR)
  # An absolute path, or one starting with %h. No spaces: Quadlet passes the value
  # straight into `podman run -v <value>:/var/lib/tailscale` and systemd splits on
  # whitespace. No trailing slash, so the ExecStartPre test and the mount agree.
  ql_assert_match TS_STATE_DIR "$dir" '(%h|/[A-Za-z0-9._+-])[A-Za-z0-9._/+-]*[A-Za-z0-9._+-]'
  [[ $dir != */ ]] || ql_die "TS_STATE_DIR must not end with a slash: '$dir'"
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  RENDER_ARGS=()
}
