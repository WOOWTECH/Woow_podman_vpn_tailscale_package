#!/usr/bin/env bash
# scripts/install.sh: install or update the woow-tailscale node as a rootless Quadlet unit
# (podman >= 4.4, systemd --user, linger). Idempotent: an unchanged re-run builds nothing
# and restarts nothing. Run it as the account that owns the containers, never with sudo.
#
#   scripts/install.sh [--state-dir DIR] [--rebuild | --no-build] [--build-only]
#                      [--allow-identity-change] [--no-start] [--dry-run]
#
#   --state-dir DIR          record DIR as TS_STATE_DIR (the node's identity lives there)
#   --rebuild                build the pinned image again even if it exists
#   --no-build               never build; the pinned image must already exist
#   --build-only             build the image and stop: no config, no units, no restart
#   --allow-identity-change  proceed although TS_LOGIN_SERVER or TS_HOSTNAME differ from
#                            the running node (that re-registers it: new IP, serve lost)
#   --no-start               install the unit and daemon-reload, but start nothing
#   --dry-run                render + validate + report what would change; touch nothing
#
# THIS NODE MAY BE A MANAGEMENT PATH. On a host you reach over its tailnet IP, a restart
# drops your own session for a few seconds, and a wrong state directory enrols a brand-new
# node. Adopt an existing deployment with scripts/migrate-legacy.sh, which takes a backup,
# arms a watchdog and rolls back on its own.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"

PODMAN_MIN=4.4
DEFAULT_STATE_DIR='%h/.local/share/woow-tailscale/state'
STATE=$HOME/.local/state/woow-quadlet/$TS_APP

build=auto build_only=0 no_start=0 state_dir_opt='' allow_identity=0
while (($#)); do
  case $1 in
    --state-dir) state_dir_opt=${2:?--state-dir needs a directory}; shift ;;
    --rebuild) build=always ;;
    --no-build) build=never ;;
    --build-only) build_only=1 ;;
    --allow-identity-change) allow_identity=1 ;;
    --no-start) no_start=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$TS_APP
dry() { [[ ${QL_DRY_RUN:-0} == 1 ]]; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/$TS_APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# render_units <install-envfile>: render quadlet/ into $WORK/out; sets IMAGE
render_units() {
  rm -rf "$WORK/src" "$WORK/out"
  mkdir -p "$WORK/src" "$WORK/out"
  cp -p "$REPO"/quadlet/*.container "$WORK/src/"
  ql_env_load "$1"
  RENDER_ARGS=()
  render_args "$1"
  ql_render "$WORK/src" "$1" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
  IMAGE=$(sed -n 's/^Image=//p' "$WORK/out/woow-tailscale.container" | tail -n1)
  [[ $IMAGE =~ ^localhost/woow-tailscale:[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$ ]] \
    || ql_die "unexpected Image= in quadlet/woow-tailscale.container: '$IMAGE'"
}

ensure_image() {
  if [[ $build == never ]]; then
    podman image exists "$IMAGE" || ql_die "$IMAGE does not exist and --no-build was given (run scripts/install.sh --build-only)"
    return 0
  fi
  if [[ $build == auto ]] && podman image exists "$IMAGE"; then
    ql_info "image $IMAGE is present (use --rebuild to build it again)"
    return 0
  fi
  if dry; then ql_info "[dry-run] would build $IMAGE from Containerfile"; return 0; fi
  ql_info "building $IMAGE (base pinned in Containerfile)"
  # --format docker keeps the image's own HEALTHCHECK; the unit repeats it as HealthCmd.
  podman build --format docker -t "$IMAGE" -f "$REPO/Containerfile" "$REPO" \
    || ql_die "building $IMAGE failed; nothing was changed"
}

# ---- --build-only: image only ----------------------------------------------------------
if ((build_only)); then
  ql_require_rootless
  ql_require_podman_min "$PODMAN_MIN"
  export QL_ENV_MODE_CHECK=0
  if [[ -f $TS_INSTALL_ENV ]]; then render_units "$TS_INSTALL_ENV"; else render_units "$REPO/config/woow-tailscale.env.example"; fi
  ensure_image
  ql_info "image ready: $IMAGE"
  exit 0
fi

# ---- 1. host preflight -------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
ql_lock "$TS_APP"

# ---- 2. the two env files ----------------------------------------------------------------
ql_env_ensure "$REPO/config/woow-tailscale.env.example" "$TS_INSTALL_ENV"
created=$QL_ENV_CREATED
ql_env_ensure "$REPO/config/node/tailscale.env.example" "$TS_NODE_ENV"
created=$((created + QL_ENV_CREATED))
if [[ -n $state_dir_opt ]]; then
  [[ $state_dir_opt == /* || $state_dir_opt == '%h'/* ]] || ql_die "--state-dir needs an absolute path (or one starting with %h)"
  state_dir_opt=${state_dir_opt%/}
  if dry; then ql_info "[dry-run] would set TS_STATE_DIR=$state_dir_opt"; else ql_env_set "$TS_INSTALL_ENV" TS_STATE_DIR "$state_dir_opt"; fi
fi
if ((created)) && ! dry; then
  ql_info "created the settings files. Edit $TS_NODE_ENV (at least TS_HOSTNAME, and TS_AUTHKEY"
  ql_info "for an unattended first login), then run $0 again."
  exit 0
fi
install_env=$TS_INSTALL_ENV
[[ -f $install_env ]] || install_env=$REPO/config/woow-tailscale.env.example
node_env=$TS_NODE_ENV
[[ -f $node_env ]] || node_env=$REPO/config/node/tailscale.env.example

# The node env is data for podman: reject what --env-file would misread (inline comments,
# CRLF, quotes) before anything restarts.
ql_env_load "$node_env"
hostname_want=$(ql_env_get TS_HOSTNAME '')
login_want=$(ql_env_get TS_LOGIN_SERVER '')
udp_port=$(ql_env_get TS_UDP_PORT 41641)
web_ui=$(ql_env_get TS_WEB_UI false)
ql_assert_match TS_UDP_PORT "$udp_port" '[1-9][0-9]{2,4}'
[[ $hostname_want != woow-node ]] || ql_die "set TS_HOSTNAME in $TS_NODE_ENV to this host's tailnet name (it is still the example value)"
[[ -n $hostname_want ]] || ql_die "TS_HOSTNAME is empty in $TS_NODE_ENV"

# ---- 3. render and validate ----------------------------------------------------------------
render_units "$install_env"
state_dir=$(ql_expand_home "$(ts_env_value "$install_env" TS_STATE_DIR)")

# ---- 4. guards ------------------------------------------------------------------------------
ql_check_container_collision "$TS_CONTAINER" "$TS_UNIT"
# Two tailscaled on one state directory means key flapping and a lost identity.
ql_check_path_mounted "$state_dir" "$TS_CONTAINER"
# The identity guard: never silently re-register a running node. Values are compared by
# hash and never printed.
if podman container exists "$TS_CONTAINER" >/dev/null 2>&1; then
  # (the wanted values were read from the node env file before QL_ENV was reloaded)
  for k in TS_LOGIN_SERVER TS_HOSTNAME; do
    running=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$TS_CONTAINER" 2>/dev/null | sed -n "s/^$k=//p" | tail -n1)
    case $k in TS_LOGIN_SERVER) wanted=$login_want ;; *) wanted=$hostname_want ;; esac
    if [[ $(printf '%s' "$running" | sha256sum) != $(printf '%s' "$wanted" | sha256sum) ]]; then
      ((allow_identity)) || ql_die "$k differs from the running $TS_CONTAINER container. Changing it logs this node out and re-registers it: new node key, new tailnet IP, serve configuration gone. Re-run with --allow-identity-change if that is what you want"
      ql_warn "$k differs from the running container (--allow-identity-change): the node will re-register"
    fi
  done
fi
if [[ $state_dir == "$(ql_expand_home "$DEFAULT_STATE_DIR")" ]]; then
  if [[ ! -d $state_dir ]] && ! dry; then
    (umask 077 && mkdir -p "$state_dir")
    ql_info "created the state directory $state_dir (a fresh node will be enrolled)"
  fi
elif [[ ! -d $state_dir ]]; then
  ql_die "TS_STATE_DIR=$state_dir does not exist. install.sh creates only the default path, so a typo cannot enrol a brand-new node: create it yourself, or point TS_STATE_DIR at the existing one"
fi
# A second node on this host needs its own UDP port.
if [[ $(podman container inspect --format '{{.State.Running}}' "$TS_CONTAINER" 2>/dev/null || true) != true ]]; then
  if ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE ":$udp_port\$"; then
    ql_die "UDP port $udp_port is already in use on this host (another tailscale node?). Set TS_UDP_PORT in $TS_NODE_ENV"
  fi
fi
ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
  || ql_die "the rendered unit failed the dry-run; nothing was installed"
ql_check_unit_shadow "$TS_UNIT" "$TS_APP"

# ---- 5. image before any unit change --------------------------------------------------------
ensure_image
if dry && ! podman image exists "$IMAGE" >/dev/null 2>&1; then
  ql_info "[dry-run] $IMAGE is not built yet"
else
  ql_pull_images "$WORK/out"
fi
# Restart when the image behind the pinned tag, or the node env file, changed: podman reads
# the env file only when the container is created.
if podman image exists "$IMAGE" >/dev/null 2>&1; then
  want_id=$(podman image inspect --format '{{.Id}}' "$IMAGE")
  have_id=$(podman container inspect --format '{{.Image}}' "$TS_CONTAINER" 2>/dev/null || true)
  if [[ -n $have_id && $have_id != "$want_id" ]]; then
    ql_info "$TS_CONTAINER runs image ${have_id:0:12}; $IMAGE is ${want_id:0:12}: it will restart"
    ql_mark_changed "$TS_APP" "$TS_UNIT"
  fi
fi
env_sha=$(sha256sum "$node_env" | cut -d' ' -f1)
if [[ -f $STATE/node-env.sha256 && $(cat "$STATE/node-env.sha256") != "$env_sha" ]]; then
  ql_info "$TS_NODE_ENV changed since the last install: $TS_CONTAINER will restart"
  ql_mark_changed "$TS_APP" "$TS_UNIT"
fi

# ---- 6. install and apply --------------------------------------------------------------------
changed=$(ql_install_files "$WORK/out" "$TS_APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if dry; then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
(umask 077 && mkdir -p "$STATE" && printf '%s\n' "$env_sha" >"$STATE/node-env.sha256")
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start $TS_UNIT"
  exit 0
fi
ql_apply_units "$TS_APP" "$TS_UNIT"

# ---- 7. wait for the node, then smoke ---------------------------------------------------------
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$TS_CONTAINER" 120 \
  || ql_warn "$TS_CONTAINER is not healthy yet; tailscaled may still be logging in"
state=''
if ql_wait_until 120 "tailscaled to report a backend state" \
  bash -c "state=\$(podman exec $TS_CONTAINER sh -c 'tailscale status --json 2>/dev/null | jq -r .BackendState' 2>/dev/null); [[ \$state == Running || \$state == NeedsLogin ]]"; then
  state=$(ts_backend_state "$TS_CONTAINER")
fi
case $state in
  Running)
    ip=$(ts_node_ip "$TS_CONTAINER")
    id=$(ts_node_id "$TS_CONTAINER")
    (umask 077 && printf 'node_id=%s\ntailnet_ip=%s\nhostname=%s\n' "$id" "$ip" "$hostname_want" >"$STATE/identity")
    ql_info "node $hostname_want is up: $ip (node id $id)"
    ;;
  NeedsLogin)
    ql_warn "the node is not logged in yet. Either put a pre-auth key in TS_AUTHKEY and re-run,"
    ql_warn "or open the login URL from the log:"
    printf '    podman logs %s 2>&1 | grep -m1 -A2 "To authenticate"\n' "$TS_CONTAINER" >&2
    ;;
  *)
    ql_warn "tailscaled reports '${state:-no state}'; see: podman logs --tail 50 $TS_CONTAINER"
    ;;
esac
bash "$REPO/tests/smoke.sh" || ql_die "tests/smoke.sh failed"
cat >&2 <<EOF

woow-tailscale is installed: $IMAGE
  State dir  $state_dir   (the node identity: back it up with scripts/backup.sh)
  Status     podman exec $TS_CONTAINER tailscale status
  Logs       journalctl --user -u $TS_UNIT -f ; podman logs -f $TS_CONTAINER
  Web UI     TS_WEB_UI=$web_ui; when on it is bound to 127.0.0.1:8088 only
  Upgrade    git pull && scripts/upgrade.sh   (--watchdog on a management path)
EOF
