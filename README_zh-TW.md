# Woow Tailscale on rootless Podman（Quadlet）

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![Tailscale](https://img.shields.io/badge/tailscale-1.102.3-brightgreen)](https://tailscale.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

以 **Quadlet + systemd** 在 **rootless Podman** 上跑一個 [Tailscale](https://tailscale.com/)
節點，官方控制平面與自架 [Headscale](https://headscale.net/) 都支援。容器跑在主機 network
namespace 加 userspace networking，由使用者的 systemd 以 `Restart=always` 管理並開啟
linger，崩潰後會自動拉起，重開機後也會回來。

> **這個節點幾乎一定是進入主機的管理通道。** 從 tailnet SSH 到這個節點的位址，會落在主機的
> `127.0.0.1:22`。這裡的每一個操作（安裝、升級、遷移）都可能切斷你正在用的連線：請加
> `--watchdog`，並且從**另一條路徑**（Cloudflare tunnel、實體主控台、LAN）執行。

> **Docker / compose 使用者：** 本倉從這個版本起只支援 Quadlet。最後一個含 `compose.yml`、
> Caddy sidecar 與 bridge 網路 unit 的 commit 標記在
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package/tree/compose-final)：
> `git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package.git`。
> 該版本不再維護，而且在 podman 下重開機不會自動回來。

---

## 提供什麼

| | |
|---|---|
| **容器** | `woow-tailscale`，映像 `localhost/woow-tailscale:1.102.3-r1`，在本機由 `docker.io/tailscale/tailscale:v1.102.3`（已釘版）加上本倉 entrypoint 建置 |
| **網路** | `Network=host` 加 `--tun=userspace-networking`：不需要任何 capability，也不需要 `/dev/net/tun` |
| **身分** | bind mount 的 state 目錄 — machine key、node key、prefs 與 `tailscale serve` 設定 |
| **設定** | `~/.config/woow-tailscale/` 下兩個 0600 檔案；env 名稱與 HA add-on 的 option key 一一對應 |
| **監管** | Quadlet 產生的 `systemd --user` unit：`Restart=always`，健康檢查 `tailscale status --peers=false` |
| **腳本** | install、upgrade（watchdog + 回滾）、backup、restore、uninstall，以及從 compose／手動部署遷移 |

映像只在本機建置、不在任何 registry，所以 unit 用 `Pull=never`。發佈到 GHCR（讓新主機免建置）
是之後的工作。

---

## 為什麼是 host network + userspace

rootless Podman 無法對主機的 network namespace 授予 `NET_ADMIN`，所以 kernel 模式的 tun 在這裡
只會不斷重啟。userspace 模式不需要 capability 也不需要裝置，而且該有的都還在：

- 從 tailnet 連進這個節點會落在主機 loopback — SSH 到 tailnet IP 等於連 `127.0.0.1:22`；
- `tailscale serve` 的 TCP 轉發（存在 state 目錄裡）會送到 `127.0.0.1:<port>`；
- subnet route 與 exit node 仍可用（走 netstack，吞吐量較低）。

這是唯一支援的部署形式。被移除的 compose 設計用 bridge 網路、kernel 模式與 Caddy sidecar 做
Basic auth：它要不到需要的 capability，而且 sidecar 會收到整個 env 檔，`TS_AUTHKEY` 也在裡面。

## 系統需求

- rootless Podman ≥ 4.4（Quadlet）；已在 Podman 4.9.3 / systemd 255（Ubuntu 24.04）測試，也是
  WOOWTECH 主機的環境。
- linger，讓 unit 不需登入工作階段即可執行：`install.sh` 會開啟，polkit 拒絕時請執行
  `sudo loginctl enable-linger <user>`。
- 主機上 `TS_UDP_PORT`（預設 41641）未被占用，`install.sh` 會檢查。
- 建置映像需要一次網路存取（約 60 MB 的 Alpine 套件）。

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package.git
cd Woow_podman_vpn_tailscale_package
./scripts/install.sh
```

第一次執行會建立兩個設定檔然後停下來，讓你編輯：

```bash
$EDITOR ~/.config/woow-tailscale/tailscale.env      # 至少要填 TS_HOSTNAME
./scripts/install.sh
```

接著它會建置釘版映像、用設定檔算出 unit 內容（decision D2）、以 Quadlet generator 與
`systemd-analyze --user verify` 檢查、安裝、啟動、等待 `tailscaled` 回報狀態，最後跑
`tests/smoke.sh`。之後 `git pull` 或改設定再跑一次，只會重啟真的變動到的東西。

**首次登入。** `TS_AUTHKEY` 有值時節點會自行註冊；沒有的話安裝會停在
`BackendState=NeedsLogin`，並告訴你去哪裡拿登入網址：

```bash
podman logs woow-tailscale 2>&1 | grep -m1 -A2 'To authenticate'
```

註冊完成後請清掉 `TS_AUTHKEY` — 之後身分存在 state 目錄裡，不在那把 key。

| 參數 | 作用 |
|---|---|
| `--state-dir DIR` | 把 `DIR` 記成 `TS_STATE_DIR`（接管身分已在該目錄的既有節點） |
| `--rebuild` / `--no-build` | 強制重新建置 / 不建置（映像必須已存在） |
| `--build-only` | 只建映像就結束：不碰設定、unit 與服務（遷移前置作業用） |
| `--allow-identity-change` | 即使 `TS_LOGIN_SERVER` 或 `TS_HOSTNAME` 與執行中的節點不同也照做 — **這會讓節點重新註冊：新的 tailnet IP，serve 設定全沒** |
| `--no-start` | 只安裝與 `daemon-reload`，不啟動 |
| `--dry-run` | 只計算、驗證並報告會變更什麼，不動任何東西 |

### 設定

兩個檔案，都是 0600，都由 `config/` 下的範例產生：

| 檔案 | 誰會讀 | 內容 |
|---|---|---|
| `~/.config/woow-tailscale/woow-tailscale.env` | 只有 install／upgrade 腳本 | `TS_STATE_DIR`，會被算進 unit |
| `~/.config/woow-tailscale/tailscale.env` | **podman**（`--env-file`） | 節點自己的 `TS_*` 設定 |

第二個檔案由 podman 原樣讀取，所以必須是單純的 `KEY=value`：不要引號、不要 `export`，
**值後面不可以加 `# 註解`** — podman 會把註解文字當成值的一部分傳給 `tailscale up`。
`install.sh` 會擋掉這種檔案，CI 也會檢查範例檔。

| Key | 預設 | 作用 |
|---|---|---|
| `TS_STATE_DIR` | `%h/.local/share/woow-tailscale/state` | 節點身分存放處（寫在 `woow-tailscale.env`；`%h` 由安裝腳本展開） |
| `TS_LOGIN_SERVER` | *(空)* | 空 = 官方 Tailscale，填 URL = 自架 Headscale |
| `TS_AUTHKEY` | *(空)* | pre-auth key，只在首次登入需要 |
| `TS_HOSTNAME` | `woow-node` | 節點在 tailnet 上的名稱；維持範例值時安裝會被拒絕 |
| `TS_ACCEPT_DNS` / `TS_ACCEPT_ROUTES` | `true` | MagicDNS、接受對端的 subnet route |
| `TS_ADVERTISE_ROUTES` | *(空)* | subnet router，逗號分隔（`192.168.2.0/24`） |
| `TS_ADVERTISE_EXIT_NODE` / `TS_ADVERTISE_CONNECTOR` | `false` | 本節點提供 exit node／app connector |
| `TS_EXIT_NODE` | *(空)* | 指定某個對端當 exit node |
| `TS_SNAT_SUBNET_ROUTES` / `TS_STATEFUL_FILTERING` | `true` / `false` | subnet router 的封包處理 |
| `TS_TAGS`、`TS_ALWAYS_USE_DERP` | *(空)*、`false` | ACL tag；強制走中繼 |
| `TS_UDP_PORT` | `41641` | WireGuard 連接埠 — 一台主機一個埠只能有一個節點 |
| `TS_WEB_UI` | `false` | `tailscale web`，節點自己的管理介面（見下） |
| `TS_EXTRA_UP_ARGS`、`TS_EXTRA_TAILSCALED_ARGS`、`TS_LOG_LEVEL` | *(空)*、*(空)*、`info` | 直接傳遞 |

`TS_USERSPACE_NETWORKING` 與 `TS_WEB_LISTEN` **由 unit 強制指定**，寫在這個檔案裡沒有用：
podman 的 `--env` 優先於 `--env-file`。

### state 目錄

`TS_STATE_DIR` 是 bind mount 而不是 named volume，它就是節點本身：machine key、node key、
prefs 與 serve 設定。把它指向舊部署用的目錄，tailnet 上看不出任何變化 — 同一個 node ID、
同一個 tailnet IP、同一組 serve 轉發。

目錄不存在時 unit 會拒絕啟動（`ExecStartPre=test -d`），因為路徑打錯會變成註冊一個全新節點、
拿到新 IP、serve 轉發全部消失。同樣理由，`install.sh` 只會替你建立預設路徑。

兩個 tailscaled 共用一個 state 目錄會讓金鑰互相覆蓋：若有其他執行中的容器 bind mount 了同一個
路徑，`install.sh` 會中止。

### `tailscale web` 的安全性

`tailscale web` 是**可寫、且完全沒有認證**的管理介面 — 連得到的人可以改這個節點的設定，也可以
把它登出。它預設關閉，而且 unit 強制 `TS_WEB_LISTEN=127.0.0.1:8088`，不可能被發佈到 LAN 介面。
要用就明確地開一條路：

```bash
ssh -L 8088:127.0.0.1:8088 <user>@<host>              # 然後開 http://127.0.0.1:8088/
podman exec woow-tailscale tailscale serve --bg --tcp=8088 tcp://127.0.0.1:8088
```

注意 tailnet serve 等於把它交給**整個 tailnet 的每一個成員**。若真的需要放到 LAN，不要去改監聽
位址，而是在主機上用一個帶認證的 reverse proxy 擋在 `127.0.0.1:8088` 前面
（`examples/nginx-basic-auth.conf` 是範本）。unit 強制的監聽位址與 `tests/smoke.sh` 都會把
loopback 以外的 8088 視為失敗。

### userspace 模式下的 subnet router 與 exit node

兩者都能用（走 netstack）。設定 `TS_ADVERTISE_ROUTES`（或 `TS_ADVERTISE_EXIT_NODE=true`）後重跑
`./scripts/install.sh`，再到管理主控台核准路由。吞吐量會低於 kernel 模式的節點；流量大的 subnet
router 請用專用主機跑 kernel 模式，不要用 rootless Podman。

### 一台主機跑多個節點

第二個節點要有自己的 `TS_UDP_PORT` 與 `TS_STATE_DIR`，容器與 unit 也要改名。連接埠已被占用時
`install.sh` 會拒絕安裝。

## 升級

```bash
git pull                                   # 取得新的釘版 tag
./scripts/upgrade.sh                       # 這條是管理通道時：--watchdog 15m
./scripts/upgrade.sh --commit              # 保留升級，解除 watchdog
./scripts/upgrade.sh --rollback            # 立刻回到前一版 unit 與映像
```

流程是：備份 state → 在節點仍執行時建置新映像 → 安裝並重啟 → 等待 `Running` 且 **node ID 與
tailnet IP 與升級前相同** → 跑 smoke 測試。任何一項失敗，它會自動裝回前一版 unit 並以舊映像重啟。

`--watchdog N` 會先在 linger 的 user manager 裡放一個 dead-man 計時器：`N` 之內沒有 `--commit`，
前一版 unit 與映像就會自動回來。只要你是透過這個節點的 tailnet 位址連進主機，就該用它，而且要
從另一條路徑執行升級。

## 備份與還原

```bash
./scripts/backup.sh                        # 熱備份：tailscaled 的 state 寫入是原子的
./scripts/backup.sh --cold                 # 停機備份（數秒）
./scripts/restore.sh ~/backups/woow-tailscale/<timestamp>
./scripts/restore.sh ~/backups/woow-tailscale/<timestamp> --with-config
```

每次執行寫出一個以時間戳命名的目錄，內含 state 目錄與兩個設定檔，0700 目錄下的 0600 檔案，
每個檔案都附 `.sha256`。

**備份就是節點身分，設定檔裡還可能有 `TS_AUTHKEY`：請比照私鑰保管。** 在別台主機還跑著同一個
身分時還原，兩邊會互相搶線 — 先退掉另一台。`restore.sh` 會把現有 state 目錄移開（不刪除），
啟動後再驗證 node ID。

## 移除

```bash
./scripts/uninstall.sh                     # 停止並移除 unit，保留身分
./scripts/uninstall.sh --logout            # 先乾淨地離開 tailnet
./scripts/uninstall.sh --purge --yes       # 連 state 目錄一起刪（刪前先做最後一份備份）
```

移除 unit 會讓這台主機的 tailnet 通道消失。如果你只有這條路進得去，請先準備另一條。
`--purge` 會永久銷毀節點身分。

## 從既有的 compose／手動部署遷移

`scripts/migrate-legacy.sh` 會接管執行中的 `woow-tailscale` 容器並**保留身分**：沿用同一個 state
目錄，所以 node key、tailnet IP 與 serve 設定都不變。舊部署用 named volume（compose 的
`*_tailscale-state`，或舊 Quadlet 的 `woow-tailscale-state`）時，會在容器停止後把內容複製到新目錄；
本來就是 bind mount 的話直接沿用。

```bash
./scripts/migrate-legacy.sh --dry-run            # 看它會推導出什麼、會做什麼
./scripts/migrate-legacy.sh --watchdog 15m       # 實際遷移
./scripts/migrate-legacy.sh --watchdog 15m --allow-broader pi-web   # 主機上有 coding agent 容器時
# ... 驗證：node id 相同、IP 相同、serve 轉發有回應 ...
./scripts/migrate-legacy.sh --commit             # 保留，解除 watchdog
./scripts/migrate-legacy.sh --rollback           # 觀察期內隨時可把舊容器換回來
./scripts/migrate-legacy.sh --status             # 這次遷移留下了什麼
./scripts/migrate-legacy.sh --finish             # 觀察期結束：移除舊容器與舊 unit 檔
```

**請從被遷移的 tailnet 位址以外的路徑執行。** 保護機制依重要性排列：

- **SSH 路徑鎖**（`~/.local/state/woow-migrate/ssh-path.lock`）：同一台主機的兩條進入路徑不可以在
  同一天遷移。如果另一條是 Cloudflare tunnel 容器，那個遷移必須取同一把鎖；
- **dead-man watchdog**：transient systemd timer 會在 `--watchdog`（預設 15m）之後自動把舊容器換
  回來，除非你執行 `--commit`；
- 切換動作跑在 **transient systemd unit** 裡，終端機斷線不會讓它做到一半；
- 新舊容器**絕不同時執行**（同一個 state 目錄、同一個 UDP 埠），回滾一律先停新的；
- 放行與否的判準是節點身分：node ID 與 tailnet IP 必須與遷移前相同。

過程中會轉換舊的 env 檔（丟掉 Caddy 的 `BASIC_AUTH_*`、`CADDY_LAN_PORT` 以及現在由 unit 強制的
設定）；已經轉換過的檔案可用 `--keep-env` 保留原樣。

### transient unit 看得到什麼

切換與 watchdog 都跑在 transient `systemd --user` unit 裡，而 `systemd-run --user` 是以
**user manager 的環境**啟動 unit，不是啟動遷移的那個 shell 的環境。所以你事先 export 的變數，
只有在 `scripts/watchdog.sh` 的 `TS_DETACHED_ENV` 有列名、並以 `--setenv` 帶進去時才到得了
detach 出去的那一半（`QL_PATH_MOUNT_ALLOW`、`WOOW_SSH_PATH_LOCK` 以及 quadlet-lib 的路徑、
守衛、等待旋鈕都在裡面；`QL_DRY_RUN` 刻意不帶）。

`--allow-broader NAME`（可重複）是設定前者的正式寫法：宣告某個容器持有的 mount 合理地**包含**
state 目錄——pi-web 的 `Volume=%h:/host%h` 把 `$HOME` 底下每個路徑都給了 coding agent，自然也
包含 tailscale 的 state 目錄——並對它關掉共用函式庫的 broader-mount 警告。發出該警告的檢查在
`install.sh` 裡，而遷移時 `install.sh` **只會在 swap unit 裡執行**，正好就是環境被丟掉的地方。
`--status` 會印出目前生效的允許清單。

**停機時間：tailnet 通道與所有 `tailscale serve` 轉發約中斷 15-30 秒。**

## 安全性

- **這個節點是進入主機的通道。** tailnet 連線會落在主機 loopback，所以連得到節點 tailnet 位址的
  人，就連得到那些「認為 loopback 就是可信」的 `127.0.0.1` 服務。tailnet ACL 要收緊，並記得
  `tailscale serve` 轉發等於把一個 loopback 埠公開給整個 tailnet。
- `tailscale web` 沒有認證且可寫；預設關閉，且被 unit 綁在 `127.0.0.1`。開啟前請先看上面那節。
- 節點以 rootless 執行，不加任何 capability、不掛任何裝置。容器逃逸落到的是一般帳號。
- 設定裡唯一的秘密是 `TS_AUTHKEY`，只在首次登入需要，之後請清空。本倉不含任何真實秘密，也不會
  把秘密寫進 unit 檔。
- 備份就是節點身分：0700 目錄下的 0600 檔案，請放在你放私鑰的地方。
- `install.sh` 與 `migrate-legacy.sh` 的身分守衛會**以雜湊比對** `TS_LOGIN_SERVER` 與
  `TS_HOSTNAME`（兩者都不會被印出來），拒絕在你沒察覺時重新註冊節點。

## 疑難排解

| 現象 | 原因與處理 |
|---|---|
| `install.sh` 拒絕：env 檔有行內註解／引號／CRLF | podman 的 `--env-file` 會把它們當成值的一部分；修掉那一行 |
| `install.sh` 拒絕：`TS_HOSTNAME` 還是 `woow-node` | 改成這台主機真正的 tailnet 名稱 |
| `install.sh` 拒絕：state 目錄不存在 | 只有預設路徑會自動建立；自己建，或把 `TS_STATE_DIR` 指向既有目錄 |
| `install.sh` 拒絕：`TS_LOGIN_SERVER`／`TS_HOSTNAME` 與執行中的節點不同 | 這個改動會讓節點重新註冊；確定要這樣就加 `--allow-identity-change` |
| `install.sh` 拒絕：已存在名為 `woow-tailscale` 的容器 | 那不是我們建立的；改用 `scripts/migrate-legacy.sh`，它會留著舊容器供回滾 |
| `install.sh` 拒絕：UDP 41641 已被占用 | 主機上已有其他節點；設定 `TS_UDP_PORT` |
| swap unit 的 journal 警告 "sits inside a broader mount held by running container(s)" | 有持有主機檔案的容器（pi-web 的 `%h:/host%h`）包含了 state 目錄；改用 `--allow-broader pi-web` 重跑。在 `--setenv` 修好之前，只 export `QL_PATH_MOUNT_ALLOW` 是沒有用的 |
| `BackendState=NeedsLogin` | 沒有 `TS_AUTHKEY`：從 `podman logs woow-tailscale` 取登入網址 |
| 節點正常，但主機上的服務從 tailnet 連不到 | 那些服務只聽 LAN 位址；userspace 模式下流量是從 `127.0.0.1` 進來的 |
| 兩個節點互相搶線 | 兩個 tailscaled 共用一個 state 目錄，或同一份身分被還原到兩台主機 |

## 目錄結構

```
quadlet/
  woow-tailscale.container   unit 本體，以 @@TOKEN@@ 表示各主機不同的值
  render-vars                install.sh 唯一可以取代的變數清單
config/
  woow-tailscale.env.example -> ~/.config/woow-tailscale/woow-tailscale.env (0600)
  node/tailscale.env.example -> ~/.config/woow-tailscale/tailscale.env      (0600，podman 會讀)
scripts/
  install.sh upgrade.sh uninstall.sh backup.sh restore.sh migrate-legacy.sh
  common.sh render-args.sh watchdog.sh
  lib/quadlet-lib.sh         內嵌的 WOOWTECH Quadlet 函式庫（請勿修改；CI 會檢查雜湊）
tests/
  dryrun.sh dryrun.local.sh  render + quadlet -dryrun + systemd-analyze verify（CI）
  smoke.sh                   實機安裝後檢查
  detached-env.sh            transient unit 有帶到該帶的環境變數（CI）
  fixtures/                  dry-run 用的各主機變體
Containerfile entrypoint.sh  映像：釘版的上游 base + env 驅動的 entrypoint
examples/nginx-basic-auth.conf  在 127.0.0.1:8088 前面加認證
docs/history/HANDOFF-v1.md   已退役的 compose + bridge + Caddy 設計，保留為歷史
.github/workflows/           quadlet-ci.yml（dry-run、shellcheck）、scripts.yml（detached 環境）、
                             image.yml（建置與版本檢查）
```

## 姊妹倉

| Repo | 部署載體 | 對象 |
|---|---|---|
| [`Woow_ha_vpn_tailscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_tailscale_package) | HAOS / HA Supervised | Home Assistant 使用者 |
| **本倉** | rootless Podman + systemd | 任何 Linux 主機 |
| [`Woow_ha_vpn_headscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_headscale_package) | HAOS / HA Supervised | 想自架 control plane 的人 |

三倉功能對稱，env 名稱與 add-on 的 option key 一一對應，所以一台主機可以同時跑 headscale 與
tailscale，兩邊 mesh 也能互通。

| 面向 | HA add-on 版 | 本倉 |
|---|---|---|
| Subnet router / Exit node / Taildrop / Serve / Funnel | ✅ | ✅ |
| Taildrive HA folders | ✅ | ❌（這裡沒有 HA folders） |
| Web UI 保護 | HA Ingress 帳號 | 只綁 loopback；要對外請自行加認證 |
| 設定方式 | HA UI options | `~/.config/woow-tailscale/tailscale.env` |
| 自動啟動 | HA supervisor | systemd user unit（Quadlet） |

## 授權

套件：MIT — 見 [LICENSE](LICENSE)。上游 Tailscale client 為 BSD-3-Clause。
