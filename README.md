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

## Licence

Package: MIT — see `LICENSE`. Upstream Tailscale client: BSD-3-Clause.
