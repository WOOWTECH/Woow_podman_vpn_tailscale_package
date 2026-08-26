# HANDOFF — Woow_podman_vpn_tailscale_package（v1 initial build）

> 版本：v1（initial build，2026-08-26）
> 對稱姊妹倉：`Woow_ha_vpn_tailscale_package`（HA add-on 版）
> 目標部署：`Hermes Agent (192.168.2.197)` 為第一測試點，`podman-mcp (192.168.2.191)` 為次候選
> 語言：文件 zh-TW + English 技術詞；commit message 英文

---

## 0. TL;DR

- 本倉是 `Woow_ha_vpn_tailscale_package` 的**功能鏡像、非程式碼鏡像** — HA add-on 走 s6-overlay + bashio + hassio_api，這條路徑跟 podman 不合；改用「official `tailscale/tailscale:stable` + 我們自寫的 env-driven entrypoint」達到同樣的用戶行為。
- 兩種部署形式：`compose.yml`（測試用）與 systemd `.container` quadlet（生產用，rootless）。
- Web UI 走 Caddy sidecar + Basic Auth，本倉自帶 Caddyfile 範例。
- 第一步：在 Hermes Agent (192.168.2.197) 用 quadlet 起動、對接 `podman-mcp.woowtech.io` 上的 Headscale。

---

## 1. 倉庫現狀

```
Woow_podman_vpn_tailscale_package/
├── README.md                           # 部署 quickstart（compose + quadlet 兩形式）
├── LICENSE                             # MIT + upstream Tailscale BSD-3-Clause 致謝
├── HANDOFF.md                          # 本文件
├── Containerfile                       # FROM tailscale/tailscale + iptables/jq/tini + entrypoint
├── entrypoint.sh                       # 讀 TS_* env → 起 tailscaled + tailscale up (+ web UI)
├── compose.yml                         # 2 服務：tailscale + caddy
├── .env.example                        # env var 對照 HA option key 說明
├── podman-tailscale.network            # quadlet：shared bridge network
├── podman-tailscale.container          # quadlet：主 container（NET_ADMIN + /dev/net/tun）
├── podman-tailscale-proxy.container    # quadlet：Caddy 反代
└── examples/
    ├── Caddyfile                       # LAN basic-auth 反代範本（tls internal）
    └── nginx-basic-auth.conf           # nginx 替代方案
```

---

## 2. 設計決策紀錄（跟 HA 版對照）

| 面向 | HA 版做法 | 本倉做法 | 理由 |
|------|-----------|----------|------|
| Base image | `ghcr.io/hassio-addons/base/*:21.0.2`（Alpine + s6 + bashio） | `docker.io/tailscale/tailscale:stable`（Alpine + tailscaled） | 官方維護、跟新 tailscale 版本、免自己 pin `TAILSCALE_VERSION` |
| Config 來源 | HA options.json → `bashio::config` | `.env` file → shell `${VAR}` | podman 沒 hassio_api |
| Service supervision | s6-overlay（tailscaled/nginx/magicdns proxies/...） | 單一 tailscaled 前景 + `tailscale web` 子行程；systemd/podman 負責重啟 | 少一層 runtime，quadlet 已提供 restart policy |
| Web UI | HA Ingress（帳號=HA user） | Caddy sidecar + Basic Auth | podman 沒 HA Ingress |
| Login server migration | `reconcile-login-server` script | entrypoint 內同名邏輯（比對 `$STATE_DIR/.last_login_server` → logout） | 邏輯 1:1 移植 |
| MagicDNS ingress/egress proxy | s6 services | **未帶** — 若需要再加 sidecar | podman host 沒有 HA 的 dnsmasq loop 問題 |
| Taildrive HA folder 分享 | 每個 folder opt-in | **拿掉** | 沒 HA folder，改用 `Taildrop` 或 podman bind-mount |
| Auto-start | HA supervisor | systemd `.container` quadlet（rootless user unit） | 生產級 |

---

## 3. Hermes (192.168.2.197) 部署 recipe

Hermes 是 rootless podman v0.20.0（見 memory `Hermes Agent on 192.168.2.197`）。SSH key：`pi-agent-woowtechopenclaw`（見 memory `pi-agent SSH access map`）。

```bash
# 從 openclaw197 帳號執行（rootless）
ssh -i ~/.ssh/pi-agent-woowtechopenclaw openclaw197@192.168.2.197

# 1) 拉倉 + build image
cd ~ && git clone https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package.git
cd Woow_podman_vpn_tailscale_package
podman build -t localhost/woow-tailscale:latest -f Containerfile .

# 2) quadlet 安裝
mkdir -p ~/.config/containers/systemd
cp podman-tailscale.network podman-tailscale.container podman-tailscale-proxy.container \
   ~/.config/containers/systemd/
cp examples/Caddyfile ~/.config/containers/systemd/
cp .env.example ~/.config/containers/systemd/tailscale.env

# 3) 編 env（重點）
$EDITOR ~/.config/containers/systemd/tailscale.env
# TS_HOSTNAME=hermes-openclaw197
# TS_LOGIN_SERVER=http://192.168.2.191:28080     # (視 podman-mcp headscale 對外 port 而定；或 http://podman-mcp.woowtech.io:28080)
# TS_AUTHKEY=<在 headscale 建的 pre-auth key>
# TS_ADVERTISE_ROUTES=192.168.2.0/24            # subnet router 給 tailnet 用
# TS_ADVERTISE_EXIT_NODE=true                    # (選) 當 exit node
# BASIC_AUTH_USER=woow
# BASIC_AUTH_HASH=<caddy hash-password 產生>

# 4) 啟動
systemctl --user daemon-reload
systemctl --user enable --now podman-tailscale-network.service
systemctl --user enable --now podman-tailscale.service
systemctl --user enable --now podman-tailscale-proxy.service
loginctl enable-linger $USER

# 5) 檢查
podman logs -f woow-tailscale
tailscale status  # (或 `podman exec woow-tailscale tailscale status`)
# Web UI: https://192.168.2.197:8443/ (BASIC_AUTH_USER + password)
```

---

## 4. 首次驗收 checklist

- [ ] `podman build` 過（Alpine + apk add + copy entrypoint 都 OK）
- [ ] `systemctl --user status podman-tailscale.service` 顯示 active(running)
- [ ] `podman logs woow-tailscale` 看到 `launching tailscaled with: ...` + `Backend in state Running`
- [ ] `podman exec woow-tailscale tailscale status --peers=false` 拿到 100.x.y.z IP
- [ ] `curl -sk https://192.168.2.197:8443/` 出現 basic-auth 提示，輸入正確後看到 tailscale web UI
- [ ] 從另一台 tailnet 裝置 `ping <hermes tailnet IP>` 通
- [ ] 若設 `TS_ADVERTISE_ROUTES` → 到 Headplane admin 核准路由 → 從其他 tailnet 裝置能 ping `192.168.2.x`
- [ ] `systemctl --user restart podman-tailscale.service` 後，tailnet 保持連線（state 有持久化）

---

## 5. 已知限制 / 已知坑

- **Rootless podman + NET_ADMIN**：podman rootless 給 NET_ADMIN 需要 kernel `CAP_NET_ADMIN` on user ns（Linux 4.14+ 一般都有）。若壞，改 `TS_USERSPACE_NETWORKING=true`（效能差、但 subnet router 仍可用）。
- **`/dev/net/tun` in rootless**：Hermes 要確認 `/dev/net/tun` 對執行帳號可讀寫；不行的話同上，切 userspace networking。
- **Caddy self-signed cert**：瀏覽器會警告。要 CA-trusted 就在 Caddyfile 換 ACME（外對外 domain）或 mkcert（LAN CA）。
- **rootless 41641/udp**：低於 1024 的 port rootless podman 不能綁；41641 沒事。若手動改 `TS_UDP_PORT=<1024`，用 rootful podman。
- **login_server 熱切換**：entrypoint 有 `logout` 邏輯，切換後首次啟動要重跑 authkey 或 interactive login。
- **Taildrive**：本倉沒帶 — 需要的話 bind-mount host 資料夾進 container，再 `podman exec ... tailscale drive share`。

---

## 6. 兩倉同步策略

跟 `Woow_ha_vpn_tailscale_package` 是**功能鏡像**（同 user-visible 行為，不同實作）。

- HA 版加新 option（如 `login_server` 加新協定支援） → 本倉 `.env.example` + `entrypoint.sh` 對應加新 env var。
- 反之亦然：本倉發現的 bugfix / 新 env 若對 HA 有用（例如 `TS_HOSTNAME` 這種 label）→ 到 HA 版加 option。
- 建議加 tag：兩倉都用 `v0.1.0`, `v0.2.0`… 對齊 minor version（一次 release 兩邊都動）。
- 若要程式碼共用：把 `entrypoint.sh` 的邏輯 factor 出來、HA 版的 `reconcile-login-server` 也共用 — 目前分家，暫不共用。

---

## 7. 出處與環境事實

- 上游：`tailscale/tailscale`（BSD-3-Clause）
- Container base：`docker.io/tailscale/tailscale:stable`（tailscale 官方 image）
- Reverse proxy：`docker.io/caddy:2-alpine`（Apache-2.0）
- 目標 host 1：Hermes Agent, `192.168.2.197`, rootless podman v0.20.0
- 目標 host 2：podman-mcp.woowtech.io, `192.168.2.191`, rootless podman + systemd
