#!/usr/bin/env bash
set -euo pipefail
status="$(tailscale status --json)"
jq -e '.BackendState == "Running"' >/dev/null <<<"$status"
serve="$(tailscale serve status --json)"
jq -e '
  (type == "object") and
  (((keys - ["TCP", "Web"]) | length) == 0) and
  ((.Web // {}) == {}) and
  (.TCP | type == "object") and
  ((.TCP | keys | sort) == ["18069","18081"]) and
  (.TCP["18081"].TCPForward == "127.0.0.1:18081") and
  (.TCP["18069"].TCPForward == "127.0.0.1:18069")
' >/dev/null <<<"$serve"
for port in 18081 18069; do
  timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port"
done
