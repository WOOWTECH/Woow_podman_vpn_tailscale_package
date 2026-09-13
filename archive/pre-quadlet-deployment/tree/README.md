# Woow Tailscale — Podman deployment

以 Podman 部署官方 [Tailscale](https://tailscale.com/) client，支援官方 Tailscale SaaS 與自架 [Headscale](https://headscale.net/)（透過 `TS_LOGIN_SERVER` env 切換）。功能對照 [`Woow_ha_vpn_tailscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_tailscale_package)（HA Add-on 版），差別只在部署載體：

| 面向 | HA add-on 版 | 本倉（Podman 版） |
|------|--------------|-------------------|
| 部署 | HA supervisor 商店 | `podman-compose` 或 systemd quadlet |
| 設定 | HA UI（options.json）| `.env` 檔案（env var 名對照 HA option key） |
| Web UI 保護 | HA Ingress 帳號 | Caddy sidecar + Basic Auth（本倉自帶範例） |
| Taildrive HA folders | ✅ | ❌（podman 沒 HA folders） |
| Subnet router / Exit node / Taildrop / Serve / Funnel | ✅ | ✅ |
| 自動起動 | HA supervisor | systemd `.container` quadlet |

## 兩種部署形式

### A. Compose（開發、測試最快）

```bash
git clone https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package.git
cd Woow_podman_vpn_tailscale_package
cp .env.example .env
# 編輯 .env：至少填 TS_HOSTNAME，若要用 headscale 填 TS_LOGIN_SERVER
# 生 basic auth hash：
podman run --rm docker.io/caddy:2-alpine caddy hash-password --plaintext 'your-password'
# 貼回 .env 的 BASIC_AUTH_HASH

podman-compose up -d --build
podman logs -f woow-tailscale       # 抓 login URL（第一次註冊）
```

**Web UI**：`https://<host_ip>:8443`（Caddy 自簽 → 瀏覽器要接受一次；帳號密碼即 `.env` 裡的 `BASIC_AUTH_USER` / plaintext password）。

### B. Systemd quadlet（生產、開機自動起）— 推薦 Hermes / 191

Rootless user unit，不需 root：

```bash
# 1) 拉 repo 並 build image
git clone https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package.git
cd Woow_podman_vpn_tailscale_package
podman build -t localhost/woow-tailscale:latest -f Containerfile .

# 2) 把 quadlet 檔案 + 設定放到 user 目錄
mkdir -p ~/.config/containers/systemd
cp podman-tailscale.network       ~/.config/containers/systemd/
cp podman-tailscale.container     ~/.config/containers/systemd/
cp podman-tailscale-proxy.container ~/.config/containers/systemd/
cp examples/Caddyfile             ~/.config/containers/systemd/
cp .env.example                   ~/.config/containers/systemd/tailscale.env
# 編 tailscale.env

# 3) reload + enable
systemctl --user daemon-reload
systemctl --user start podman-tailscale-network.service podman-tailscale.service podman-tailscale-proxy.service
loginctl enable-linger $USER    # 使用者登出後 quadlet 仍在跑

# 4) 檢查
systemctl --user status podman-tailscale.service
podman logs -f woow-tailscale
```

## 檔案清單

| 檔案 | 用途 |
|------|------|
| `Containerfile` | Base=`docker.io/tailscale/tailscale:stable`，加 `entrypoint.sh` + iptables/jq/tini |
| `entrypoint.sh` | 讀 `TS_*` env → 起 `tailscaled` + `tailscale up`；含 login_server migration 邏輯 |
| `compose.yml` | podman-compose / docker-compose；tailscale + caddy 兩服務 |
| `podman-tailscale.network` | quadlet 網段定義 |
| `podman-tailscale.container` | quadlet：tailscale 主容器 |
| `podman-tailscale-proxy.container` | quadlet：Caddy 反代 basic-auth |
| `.env.example` | 所有 env var 對照 HA option key 的說明 |
| `examples/Caddyfile` | LAN Caddy 反代範本（basic auth + tls internal） |
| `examples/nginx-basic-auth.conf` | nginx 反代替代方案 |

## 環境變數（節錄；完整見 [`.env.example`](./.env.example)）

| Env | HA option 對照 | 說明 |
|-----|---------------|------|
| `TS_LOGIN_SERVER` | `login_server` | 空=官方，填 URL=Headscale |
| `TS_AUTHKEY` | (HA UI 貼) | pre-auth key；空 = interactive |
| `TS_HOSTNAME` | `hostname`（HA host 名） | tailnet 顯示名 |
| `TS_ADVERTISE_ROUTES` | `advertise_routes` | CSV，subnet router |
| `TS_ADVERTISE_EXIT_NODE` | `advertise_exit_node` | bool |
| `TS_USERSPACE_NETWORKING` | `userspace_networking` | true = 免 NET_ADMIN |
| `TS_WEB_UI` | (HA Ingress 自動)  | 開 `tailscale web` on 8088 |

## 與姊妹倉的關係

| Repo | 部署載體 | 對象 |
|------|---------|------|
| [`Woow_ha_vpn_tailscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_tailscale_package) | HAOS / HA Supervised | Home Assistant 使用者 |
| **本倉** `Woow_podman_vpn_tailscale_package` | Rootless Podman + systemd | 泛用 Linux 主機（Hermes 197、podman-mcp 191、任何 podman 環境） |
| [`Woow_ha_vpn_headscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_headscale_package) | HAOS / HA Supervised | 想自架 control plane 的人 |

三倉功能對稱 → 一個 HA host 可以同時裝 headscale + tailscale add-on；一台 podman host 可以裝 headscale + tailscale container；兩邊 mesh 可互通。

## Headscale service gateway

The gateway lifecycle is opt-in and does not change the Compose/Quadlet deployment above. It runs a separate rootless container named `woow-tailscale-gateway`.

### Gateway prerequisites

- Rootless Podman **4.9.3 or newer**, Python 3, Bash, `jq`, `curl`, `timeout`, `flock`, `realpath`, `tar`, and `sha256sum`.
- A running Headscale server at exactly **0.29.3**, in the container named `headscale`, with exactly one numeric user named `default`.
- Nginx Proxy Manager administration answering on host loopback port `18081`, and Odoo answering on host loopback port `18069`. Their canonical user units must use immutable `sha256:` image identities, declare every mount explicitly, and label the containers with `org.woow.managed-by=systemd-user` plus `org.woow.owner-unit=<unit-name>`; the live restart gate verifies these exact declarations and runtime identities.
- A checkout path without whitespace and a working user systemd session.

Gateway mode uses `--network=host`, so container loopback is host loopback. Tailscale itself uses `--tun=userspace-networking`; no TUN device, `NET_ADMIN`, `NET_RAW`, published Podman port, or bridge network is required. Tailscale Serve exposes only tailnet TCP `18081` and `18069`, forwarding to the same host-loopback ports. Nginx Proxy Manager's existing public HTTP/HTTPS listeners are unchanged. The Tailscale web UI and Caddy are disabled in gateway mode.

### Gateway configuration

```bash
cp .env.gateway.example .env.gateway
chmod 600 .env.gateway
$EDITOR .env.gateway
```

`.env.gateway` is parsed as data, never sourced by a shell. Keep the fixed Headscale container, user, and volume names from the example; set only the gateway hostname and local Headscale HTTP(S) URL as appropriate. Never add an enrollment credential to this file.

### Deploy and verify

```bash
scripts/deploy.sh
scripts/verify.sh
```

First enrollment creates a reusable five-minute Headscale credential, captures it directly in protected files, mounts only a mode-`600` file into a temporary enrollment container, then immediately expires and deletes the credential and clears the files. Credential bytes are never placed in container environment variables or argument values. The steady-state container has no credential mount. Later deployments reuse nonempty machine state from the exactly owned `woow-tailscale-gateway-state` volume and do not create another credential; an exact-owned but empty volume is safely enrolled as recovery. Verification checks absence of this gateway's persisted enrollment-key ID only, so unrelated operator-managed keys are not altered or rejected.

### Isolated live test

```bash
scripts/live-test.sh
```

This reruns verification, enrolls a separately named temporary userspace client, requires a direct WireGuard ping and PeerAPI ping, and reaches both gateway ports through an isolated SOCKS path. Its separate five-minute credential, node, container, volume, network, and files are removed by the invocation's cleanup trap.

### User systemd and linger

Deployment installs `~/.config/systemd/user/woow-tailscale-gateway.service` and enables it for the current rootless user. Check it with:

```bash
systemctl --user is-enabled woow-tailscale-gateway.service
systemctl --user is-active woow-tailscale-gateway.service
```

For startup after logout/reboot, enable linger using the host's approved administrative procedure (commonly `loginctl enable-linger "$USER"`). Do not run the gateway as root.

### Backup and restore

Backups are cold, mode `600`, checksummed archives. The new absolute destination must exist outside this repository; it is never overwritten.

```bash
mkdir -p "$HOME/woow-gateway-backups"
scripts/backup.sh "$HOME/woow-gateway-backups/gateway-state.tar"
scripts/restore.sh "$HOME/woow-gateway-backups/gateway-state.tar" --confirm-restore
```

Restore validates archive members, checksums, checkout ownership, and the saved node identity. It takes a rollback export and restores that export automatically if verification fails. Machine state is the gateway identity: purging it requires enrollment of a new node; restoring a valid backup restores the recorded identity.

### Gateway removal

The default and explicit retain mode remove only the generated unit/container while preserving machine state and image:

```bash
scripts/remove.sh
scripts/remove.sh --retain-state
```

Permanent state deletion requires both flags:

```bash
scripts/remove.sh --purge-state --confirm-purge
```

Headscale node deletion is separate and also requires two explicit flags. Read `scripts/remove.sh --help`-equivalent usage in the script before using it; state purge cannot be undone without a backup.

### Troubleshooting

1. Run `python3 -m unittest discover -s tests -v` and `bash -n entrypoint.sh scripts/*.sh`.
2. Confirm `.env.gateway` is a regular current-user-owned mode-`600` file and `scripts/verify.sh` reports every check separately.
3. Confirm `127.0.0.1:18081` and `127.0.0.1:18069` answer without 5xx responses, Headscale reports 0.29.3, and Podman reports at least 4.9.3.
4. Do not edit generated runtime/unit files or bypass ownership failures. Use backup/restore rather than copying Podman volume host paths.
5. Scan all repository and ignored runtime content plus all diffs with `python3 -m unittest tests.test_secret_scan -v`; reviewers may also inspect `git diff --binary HEAD` directly. For live incident review, separately inspect the generated unit and `podman container inspect woow-tailscale-gateway`; sanitize `journalctl --user-unit woow-tailscale-gateway.service` before sharing it. Never paste raw inspect data, journals, machine state, or enrollment output into an issue.

### Matter Server retirement gate

Matter Server removal is irreversible and is deliberately separate from gateway deployment. Keep Matter Server installed while validating the gateway. Only after static tests, secret scan, normal verification, isolated VPN access, restart identity persistence, and a fresh protected backup all pass in the **same invocation** may an operator run:

```bash
scripts/remove-matter-server.sh --confirm-permanent-matter-removal
```

The script reruns those gates immediately, resolves exact Matter unit/container/volume/image ownership, refuses shared resources, and compares unrelated container state. It does not accept stale verification evidence and does not recreate Matter Server after removal. Record nonsecret operational evidence outside this repository.

## Licence

Package: MIT — see `LICENSE`. Upstream Tailscale client: BSD-3-Clause.
