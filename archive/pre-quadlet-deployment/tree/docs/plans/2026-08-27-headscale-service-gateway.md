# Headscale Service Gateway Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a secure, rootless Podman gateway that joins Headscale and exposes only host-loopback Nginx Proxy Manager administration and Odoo over Tailscale Serve TCP.

**Architecture:** Run the gateway with `--network=host` and `--tun=userspace-networking`, preserving its machine identity in one exactly owned named volume and reconciling two declarative Serve listeners on every start. A strict Python configuration layer and idempotent Bash lifecycle scripts create a five-minute Headscale 0.29.3 pre-auth key only for first enrollment, pass it by a mode-600 file, revoke and delete it immediately, then recreate the steady-state container without the key mount. A rootless user-systemd service owns steady-state startup; verification, isolated-client tests, backup/restore/removal, and the final Matter Server retirement all fail closed and touch only exactly identified resources.

**Tech Stack:** Bash, Python 3 standard library/unittest, Tailscale CLI and userspace `tailscaled`, declarative Tailscale Serve TCP, rootless Podman 4.9.3, Headscale 0.29.3 CLI, user systemd, curl, jq, tar, and SHA-256 manifests.

---

## Fixed contracts and execution constraints

- Implement in the repository worktree; never put real enrollment keys, `.env`, runtime state, backup archives, or live-test output in Git.
- Keep the current generic Compose/Quadlet deployment working. Gateway mode is opt-in through the new gateway lifecycle and must not enable the existing Caddy sidecar or Tailscale web UI.
- The production gateway has exactly these mappings: Tailscale TCP `18081` to host `127.0.0.1:18081`, and Tailscale TCP `18069` to host `127.0.0.1:18069`. Do not make arbitrary forwarding a gateway feature.
- The production runtime uses host networking plus userspace networking. It must not request `/dev/net/tun`, `NET_ADMIN`, `NET_RAW`, published ports, or a Podman bridge network.
- The Headscale enrollment user is the existing user named `default`. Headscale 0.29.3 requires its numeric ID for `preauthkeys create`, so resolve the ID from `headscale users list --output json`; reject missing or duplicate `default` users.
- Enrollment keys are reusable as required by the approved design, expire after five minutes, and are still revoked immediately after enrollment with `headscale preauthkeys expire --id ID`, then deleted with `headscale preauthkeys delete --id ID`. Cleanup traps make both commands best-effort on every exit after key creation.
- Pass enrollment to Tailscale as `--authkey=file:/run/secrets/headscale-preauth.key`; never read the key into a shell variable or place it in an environment variable, argv value, generated unit, container inspect data, logs, or test diagnostics.
- The enrollment container is temporary. After registration, remove it, revoke/delete the key, truncate and unlink all key-bearing temporary files, and start the steady-state service without any auth-key mount. The named state volume is the only object shared between the two runs.
- All global names must be exact: container `woow-tailscale-gateway`, state volume `woow-tailscale-gateway-state`, installed unit `woow-tailscale-gateway.service`, and project label `org.woow-tailscale.project=woow-tailscale-gateway`. Also require role, managed-by, and canonical checkout labels before reusing, stopping, restoring, or removing an existing object.
- Podman 4.9.3 is the compatibility floor. Do not rely on `podman compose`, `--replace` ownership semantics, image-inspect health metadata, newer Quadlet keys, or automatic rootless health scheduling. Use `podman container inspect`, explicit `podman healthcheck run`, `podman volume export/import`, and a conventional generated user-systemd service.
- Live tests create a separately enrolled temporary node, always revoke/delete its separate key, and always remove its container, temporary state, network, and Headscale node through an EXIT trap.
- Matter Server removal is irreversible and is the last task. It may run only after static tests, gateway verification, isolated VPN-client access, restart identity persistence, Headscale, Nginx Proxy Manager, and Odoo checks are all green in the same execution window.

### Task 1: Add strict gateway configuration and generated runtime data

**Files:**
- Create: `tests/test_gateway_config.py`
- Create: `scripts/gateway_config.py`
- Create: `.env.gateway.example`
- Modify: `.gitignore`

**Step 1: Write the failing configuration tests**

Use `unittest` and temporary files. Cover all of these cases explicitly:

```python
VALID = """\
GATEWAY_HOSTNAME=woow-service-gateway
HEADSCALE_URL=http://127.0.0.1:28080
HEADSCALE_CONTAINER=headscale
HEADSCALE_USER=default
STATE_VOLUME=woow-tailscale-gateway-state
"""

# Expected normalized runtime values are fixed, not operator-overridable.
self.assertEqual(config["TS_USERSPACE_NETWORKING"], "true")
self.assertEqual(config["TS_WEB_UI"], "false")
self.assertEqual(config["TS_SERVE_TCP_18081"], "127.0.0.1:18081")
self.assertEqual(config["TS_SERVE_TCP_18069"], "127.0.0.1:18069")
```

Test rejection of duplicate/unknown keys, shell syntax, interpolation, blank required values, invalid DNS hostnames, non-HTTP(S) or credential-bearing Headscale URLs, non-exact `default` user/volume/container values, CR/NUL/control characters, and inherited environment overrides. Test atomic rendering, directory mode `700`, file mode `600`, and output that contains no auth-key field.

**Step 2: Run the tests and verify the expected failure**

Run: `python3 -m unittest tests.test_gateway_config -v`

Expected: FAIL because `scripts/gateway_config.py` does not exist.

**Step 3: Implement the minimal strict parser and renderer**

Implement `parse-env` and `render` subcommands with only the Python standard library. Parse `.env.gateway` as data, allow comments and literal `KEY=VALUE` pairs only, use an allowlist, reject duplicates/unknowns, normalize the URL without credentials/query/fragment, and atomically write `runtime/gateway.env`. Hard-code the security-sensitive runtime values shown above plus:

```text
TS_ACCEPT_DNS=true
TS_ADVERTISE_CONNECTOR=false
TS_ALWAYS_USE_DERP=false
TS_WEB_LISTEN=127.0.0.1:8088
```

Gateway output must omit `TS_ACCEPT_ROUTES`, `TS_ADVERTISE_ROUTES`, `TS_ADVERTISE_EXIT_NODE`, `TS_SNAT_SUBNET_ROUTES`, `TS_STATEFUL_FILTERING`, and `TS_EXIT_NODE`; gateway startup rejects those variables when explicitly supplied and never emits their `tailscale up` flags.

Use `os.open(..., 0o600)` and `os.replace`; set `umask(0o077)` before creating runtime data. Do not source `.env.gateway` from Bash.

**Step 4: Run the focused and full tests**

Run: `python3 -m unittest tests.test_gateway_config -v`

Expected: all configuration tests PASS.

Run: `python3 -m unittest discover -s tests -v`

Expected: all tests PASS.

**Step 5: Commit**

```bash
git add .env.gateway.example .gitignore scripts/gateway_config.py tests/test_gateway_config.py
git commit -m "feat: add strict gateway configuration"
```

### Task 2: Make the entrypoint reconcile secure file enrollment and exact Serve state

**Files:**
- Create: `tests/test_gateway_entrypoint.py`
- Modify: `entrypoint.sh`
- Modify: `Containerfile`

**Step 1: Write failing entrypoint contract tests**

Build a fake `tailscaled`, `tailscale`, `jq`, and `sleep` command directory and run `entrypoint.sh` with a temporary state directory. Assert:

- gateway mode adds `--tun=userspace-networking` and never adds kernel routing flags;
- `TS_AUTHKEY_FILE=/run/secrets/headscale-preauth.key` produces exactly `--authkey=file:/run/secrets/headscale-preauth.key` and no key bytes in stdout/stderr;
- the entrypoint rejects a missing file, a non-regular file, a symlink, wrong mode, empty file, or an auth file outside `/run/secrets/`;
- `TS_AUTHKEY` and `TS_AUTHKEY_FILE` are mutually exclusive;
- it waits for `BackendState == "Running"` before applying Serve configuration;
- it executes `tailscale serve reset`, then exactly:

```bash
tailscale serve --bg --tcp=18081 tcp://127.0.0.1:18081
tailscale serve --bg --tcp=18069 tcp://127.0.0.1:18069
```

- restart repeats the reset and both commands, so stale listeners disappear;
- any Serve failure exits non-zero instead of leaving a healthy-looking gateway;
- gateway mode rejects `TS_EXTRA_UP_ARGS`, `TS_EXTRA_TAILSCALED_ARGS`, routes, exit-node, connector, tags, web UI, non-userspace mode, and altered forward values.

**Step 2: Run the focused test and verify failure**

Run: `python3 -m unittest tests.test_gateway_entrypoint -v`

Expected: FAIL because file auth and gateway Serve reconciliation are not implemented.

**Step 3: Implement the minimal gateway entrypoint path**

Add `TS_GATEWAY_MODE`, `TS_AUTHKEY_FILE`, `TS_SERVE_TCP_18081`, and `TS_SERVE_TCP_18069`. Keep current non-gateway behavior intact. In gateway mode, validate the fixed contract before starting `tailscaled`, use the literal `file:` reference rather than reading the secret, wait with a bounded deadline for Running state, reset/reapply both Serve commands, and disable the web process. Redact the complete auth argument in log output.

Add `curl` to the image for local health probes and live-test HTTP diagnostics. Continue to use exec arrays; do not add `eval` or unquoted word splitting in gateway mode.

**Step 4: Run entrypoint tests and syntax checks**

Run: `python3 -m unittest tests.test_gateway_entrypoint -v`

Expected: PASS.

Run: `bash -n entrypoint.sh && python3 -m unittest discover -s tests -v`

Expected: syntax check and all tests PASS.

**Step 5: Commit**

```bash
git add Containerfile entrypoint.sh tests/test_gateway_entrypoint.py
git commit -m "feat: reconcile gateway serve listeners"
```

### Task 3: Define the rootless host-network runtime and exact ownership checks

**Files:**
- Create: `tests/test_gateway_runtime.py`
- Create: `scripts/resource_ownership.py`
- Create: `scripts/container-health.sh`
- Create: `systemd/woow-tailscale-gateway.service.in`

**Step 1: Write failing runtime and ownership tests**

Add tests for rendered `podman run`/systemd contracts and fixture-based Podman inspect JSON. Require:

- `Network=host` equivalent (`--network=host`) and no `--publish`, `--device`, `--cap-add`, Caddy, web port, or bridge network;
- state mounted exactly at `/var/lib/tailscale` from `woow-tailscale-gateway-state`;
- `--env-file runtime/gateway.env`, `--sdnotify=conmon`, and `Restart=always`;
- no enrollment-key mount or auth variable in the steady-state unit;
- all expected project, role, managed-by, and canonical checkout labels;
- absent objects are accepted where appropriate, exact owned objects are accepted, and same-name foreign/mislabeled containers or volumes fail before any mutation;
- ownership resolution uses full names and labels, never suffix or substring matching;
- health fails unless backend is Running, both Serve listeners have exact TCP destinations, and both host-loopback targets accept TCP connections.

Include Podman 4.9.3 inspect fixtures where image health metadata is absent and container health lives under `.State.Health`.

**Step 2: Run and observe failure**

Run: `python3 -m unittest tests.test_gateway_runtime -v`

Expected: FAIL because the helper, health command, and service template are absent.

**Step 3: Implement runtime contracts**

Implement `resource_ownership.py check-container|check-volume|snapshot` using exact JSON fields and labels. The service template must use `%h/.config/woow-tailscale-gateway/gateway.env`, the named volume, host networking, rootless Podman, conmon sdnotify, and explicit health timings. `scripts/container-health.sh` must parse `tailscale status --json` and `tailscale serve status --json` with `jq`, verify only the two required listeners, then use Bash `/dev/tcp/127.0.0.1/{18081,18069}` with bounded timeouts.

Do not depend on a Quadlet feature newer than Podman 4.9.3. `deploy.sh` will render the conventional service template with the canonical checkout and install it under `~/.config/systemd/user/`.

**Step 4: Run runtime and full tests**

Run: `python3 -m unittest tests.test_gateway_runtime -v`

Expected: PASS.

Run: `bash -n scripts/container-health.sh && python3 -m unittest discover -s tests -v`

Expected: PASS.

**Step 5: Commit**

```bash
git add scripts/container-health.sh scripts/resource_ownership.py systemd/woow-tailscale-gateway.service.in tests/test_gateway_runtime.py
git commit -m "feat: define rootless gateway runtime"
```

### Task 4: Implement short-lived file-based Headscale enrollment and idempotent deploy

**Files:**
- Create: `tests/test_gateway_deploy.py`
- Create: `scripts/headscale_json.py`
- Create: `scripts/deploy.sh`

**Step 1: Write failing deploy tests with fake Podman and systemctl**

Cover these ordered behaviors:

1. Parse `.env.gateway` strictly and check required commands/host ports before mutation.
2. Verify the exact Headscale container is running and reports `0.29.3`.
3. Verify both host-loopback services answer before exposing them.
4. Check exact gateway container/volume ownership before stop, create, or removal.
5. If persistent state already has the expected Running node, skip all preauth-key creation and proceed idempotently.
6. For empty state, resolve exactly one `default` numeric user ID from `users list --output json`.
7. Create a reusable five-minute key using `preauthkeys create --user ID --reusable --expiration 5m --output json`, with stdout captured directly to a mode-600 temporary file.
8. Parse the response with `headscale_json.py`, atomically write only the key to a mode-600 enrollment file, and retain only the numeric preauth-key ID for cleanup.
9. Start a temporary enrollment container with the key file mounted read-only at `/run/secrets/headscale-preauth.key` and `TS_AUTHKEY_FILE` set to that path; no key appears in fake command logs.
10. Poll until the gateway node is Running; then remove the temporary container, expire and delete the preauth key immediately, clear/unlink both key-bearing files, install/start the steady-state user unit without a secret mount, and verify readiness.
11. On timeout, signal, parse error, systemd error, or verification failure after key creation, the EXIT trap removes the temporary container, expires/deletes the key, clears files, and leaves no steady-state container falsely reported as deployed.
12. Repeated deploys do not create a new key, node, volume, or duplicate unit.

Assert that scripts do not enable shell xtrace, print captured command output containing a key, use `TS_AUTHKEY`, or put secret bytes in Python exceptions.

**Step 2: Run deploy tests and verify failure**

Run: `python3 -m unittest tests.test_gateway_deploy -v`

Expected: FAIL because deploy and JSON helpers do not exist.

**Step 3: Implement the minimal deployment lifecycle**

Use `set -euo pipefail`, `umask 077`, mode-600 temporary command logs, fixed resource names, and absolute canonical paths. `headscale_json.py` must have narrow subcommands for resolving the default user, extracting `{id,key}` into separate protected files, finding the gateway node, and validating key absence; it must never print the key.

Create the volume with exact labels only if absent. Build the image in Docker format for Podman 4.9.3 health compatibility, label it as project-owned, and render/install the user unit and nonsecret gateway env atomically. Use a cleanup trap immediately after successful key creation. Treat failure to expire the key as a deployment failure; still attempt delete and local secret cleanup.

After enrollment, prove `podman inspect` for the steady container has no key file mount, no `TS_AUTHKEY*`, no published ports/capabilities/devices, host networking, and the exact state mount.

**Step 4: Run deploy tests and all local checks**

Run: `python3 -m unittest tests.test_gateway_deploy -v`

Expected: PASS.

Run: `bash -n scripts/deploy.sh && python3 -m unittest discover -s tests -v`

Expected: PASS.

**Step 5: Commit**

```bash
git add scripts/deploy.sh scripts/headscale_json.py tests/test_gateway_deploy.py
git commit -m "feat: add secure gateway enrollment"
```

### Task 5: Add comprehensive idempotent verification

**Files:**
- Create: `tests/test_gateway_verify.py`
- Create: `scripts/verify.sh`

**Step 1: Write failing verification tests**

With inspect/status fixtures and fake commands, require `verify.sh` to report individual PASS/FAIL lines and aggregate failures without leaking secret values. Check:

- strict config render and mode/ownership of `.env.gateway`, `runtime/`, installed env/unit, and state volume;
- Podman client version is at least 4.9.3 and the live Headscale server is exactly 0.29.3;
- exact image/container/volume labels and mount destination;
- host network, userspace tun, no capabilities/devices/published ports, web UI/Caddy disabled, and no auth-key env or mount;
- user unit enabled and active, container running, restart policy/systemd restart behavior, explicit `podman healthcheck run`, and resulting healthy state;
- backend Running, expected gateway hostname/node ID, exact Serve status with no extra listeners, local NPM `18081` and Odoo `18069` responses, and Headscale health;
- no active reusable/unexpired preauth key associated with the enrollment operation and no key-shaped values in runtime files, inspect JSON, journal, or repository files;
- repeated verification is read-only and produces the same result.

**Step 2: Run tests and verify failure**

Run: `python3 -m unittest tests.test_gateway_verify -v`

Expected: FAIL because `scripts/verify.sh` is absent.

**Step 3: Implement verification**

Implement bounded polling and JSON parsing rather than grepping human tables. Accept the expected Nginx Proxy Manager redirect/auth statuses and Odoo HTTP/redirect statuses, but reject connection failures and 5xx responses. Save a nonsecret mode-600 `runtime/last-verification.json` containing timestamp, commit, node ID, service results, and live-test status; it is evidence only, not a substitute for rerunning checks.

Explicitly invoke `podman healthcheck run woow-tailscale-gateway` because rootless Podman 4.9.3 health timers are not sufficient evidence. Sanitize journal output before showing failure context.

**Step 4: Run verify and full tests**

Run: `python3 -m unittest tests.test_gateway_verify -v`

Expected: PASS.

Run: `bash -n scripts/verify.sh && python3 -m unittest discover -s tests -v`

Expected: PASS.

**Step 5: Commit**

```bash
git add scripts/verify.sh tests/test_gateway_verify.py
git commit -m "feat: verify gateway security and health"
```

### Task 6: Add idempotent cold backup and transactional restore

**Files:**
- Create: `tests/test_gateway_backup_restore.py`
- Create: `scripts/backup.sh`
- Create: `scripts/restore.sh`

**Step 1: Write failing backup/restore tests**

Test fake Podman/systemd flows for:

- exact ownership checks before stop/export/import;
- backup destination must be operator-supplied, absolute, new, and outside the repository/runtime tree;
- mode-`700` staging, mode-`600` final archive, atomic rename, SHA-256 manifest, canonical metadata, and no auth key/runtime logs in the archive;
- cold backup stops the user service, exports exactly `woow-tailscale-gateway-state` with Podman 4.9.3 `podman volume export`, restarts it even on failure, and verifies the same node ID;
- restore requires `--confirm-restore`, rejects traversal/symlinks/unexpected members/checksum or manifest mismatch, and rejects a foreign target volume;
- restore takes a rollback export, stops the service, empties/imports only the exact volume with `podman volume import`, restores owner labels, starts and verifies the manifest node ID, and automatically rolls back if verification fails;
- rerunning backup with the same occupied path fails without overwrite, and rerunning a successful restore produces the same identity/state.

**Step 2: Run tests and verify failure**

Run: `python3 -m unittest tests.test_gateway_backup_restore -v`

Expected: FAIL because lifecycle scripts are absent.

**Step 3: Implement minimal safe backup and restore**

Use `flock` shared with deploy/remove to prevent concurrent lifecycle operations. Record schema version, repository commit, image identity, state volume labels, gateway node ID, and checksums. Never archive `.env.gateway`, enrollment files, journals, or `runtime/last-verification.json`. Keep rollback data until post-restore verification succeeds; clean it on success and print its protected path on rollback failure.

Do not use host volume paths or assume root ownership; use `podman volume export/import` supported by Podman 4.9.3.

**Step 4: Run focused and full validation**

Run: `python3 -m unittest tests.test_gateway_backup_restore -v`

Expected: PASS.

Run: `bash -n scripts/backup.sh scripts/restore.sh && python3 -m unittest discover -s tests -v`

Expected: PASS.

**Step 5: Commit**

```bash
git add scripts/backup.sh scripts/restore.sh tests/test_gateway_backup_restore.py
git commit -m "feat: back up and restore gateway state"
```

### Task 7: Add scoped, repeatable gateway removal

**Files:**
- Create: `tests/test_gateway_remove.py`
- Create: `scripts/remove.sh`

**Step 1: Write failing removal tests**

Require default `--retain-state` and explicit `--purge-state --confirm-purge` modes. Test that removal:

- locks against deploy/backup/restore;
- refuses foreign or ambiguously labeled resources before stopping anything;
- disables/stops only `woow-tailscale-gateway.service`;
- removes only the exact gateway container and installed generated files;
- retains the state volume and image by default;
- purges only the exact owned volume and removes the exact owned image only when no other container uses it;
- treats already absent owned resources as success;
- never logs out or deletes the persistent Headscale gateway node unless a separate explicit `--delete-headscale-node --confirm-node-delete` is provided;
- snapshots unrelated containers before removal and verifies their IDs/running/health states are unchanged afterward.

**Step 2: Run tests and verify failure**

Run: `python3 -m unittest tests.test_gateway_remove -v`

Expected: FAIL because `scripts/remove.sh` is absent.

**Step 3: Implement scoped removal**

Use exact names plus every ownership label and expected mount before mutation. Remove the unit file only after checking its canonical path and generated marker. Call `systemctl --user daemon-reload`; never use wildcard Podman or systemd removal. If node deletion is requested, resolve exactly one Headscale node by persisted node ID and use Headscale 0.29.3 `--force nodes delete --identifier ID`.

**Step 4: Run tests and syntax checks**

Run: `python3 -m unittest tests.test_gateway_remove -v`

Expected: PASS.

Run: `bash -n scripts/remove.sh && python3 -m unittest discover -s tests -v`

Expected: PASS.

**Step 5: Commit**

```bash
git add scripts/remove.sh tests/test_gateway_remove.py
git commit -m "feat: add scoped gateway removal"
```

### Task 8: Add an isolated VPN-client live test with guaranteed cleanup

**Files:**
- Create: `tests/test_gateway_live.py`
- Create: `scripts/live-test.sh`

**Step 1: Write failing orchestration tests**

Use fakes to verify this exact sequence and cleanup on every injected failure:

1. Run normal `scripts/verify.sh` first.
2. Create an isolated temporary Podman network, state volume/directory, mode-600 auth file, and unique hostname.
3. Resolve the numeric `default` user ID and create a separate reusable five-minute Headscale key.
4. Start a temporary Tailscale client with userspace networking and a SOCKS5 listener, passing auth only as `file:/run/secrets/...`.
5. Poll for the temporary node and gateway peer.
6. Run normal Tailscale ping until it reports a direct endpoint (WireGuard path), then Tailscale 1.102 `tailscale ping --peerapi`.
7. From an isolated curl container sharing only the temporary test network, use `socks5h://CLIENT:1055` to request `http://GATEWAY_TAILNET_IP:18081` and `:18069`; accept the same non-5xx service statuses as verification.
8. Restart Nginx Proxy Manager, Odoo, and the gateway only through their exact owned units/containers, then repeat both HTTP requests.
9. Remove test containers, expire/delete the test key, clear files, delete the temporary Headscale node by numeric ID, and remove temporary state/network.

Assert test resources use a unique prefix and exact labels, never the production state volume. Assert no cleanup command can target a resource not created by this invocation.

**Step 2: Run tests and verify failure**

Run: `python3 -m unittest tests.test_gateway_live -v`

Expected: FAIL because `scripts/live-test.sh` is absent.

**Step 3: Implement the isolated live test**

Use one EXIT trap installed before the first temporary resource is created and append cleanup obligations as resources appear. Capture all key-bearing Headscale output in protected files and use `headscale_json.py`; never put a key in a shell variable. Pin the temporary client/curl image references to the same reviewed image identities used by deployment, and label every temporary resource with an invocation UUID.

A DERP-only ping is not sufficient: fail unless normal ping reaches a direct endpoint within the deadline. Separately require PeerAPI ping and both HTTP checks through the userspace SOCKS path.

**Step 4: Run tests and local validation**

Run: `python3 -m unittest tests.test_gateway_live -v`

Expected: PASS.

Run: `bash -n scripts/live-test.sh && python3 -m unittest discover -s tests -v`

Expected: PASS.

**Step 5: Commit**

```bash
git add scripts/live-test.sh tests/test_gateway_live.py
git commit -m "test: add isolated gateway vpn checks"
```

### Task 9: Document operations and add repository secret scans

**Files:**
- Create: `tests/test_secret_scan.py`
- Modify: `README.md`
- Modify: `.env.gateway.example`
- Modify: `.gitignore`

**Step 1: Write failing documentation and secret-scan tests**

Require README sections and exact commands for prerequisites, `.env.gateway`, deploy, verify, live test, user-systemd/linger, backup, restore, retain/purge removal, troubleshooting, and the Matter retirement gate. Add a test that scans tracked files and Git diff for Headscale/Tailscale auth-key patterns, private keys, actual non-example credentials, runtime artifacts, and mode violations.

Also assert documentation states:

- rootless Podman 4.9.3 and Headscale 0.29.3 compatibility;
- host networking makes container loopback equal host loopback;
- userspace networking requires no TUN/capabilities;
- only tailnet ports `18081` and `18069` are served, while Nginx Proxy Manager public HTTP/HTTPS remain unchanged;
- Tailscale web UI and Caddy are disabled in gateway mode;
- enrollment is five-minute, file-based, immediately expired/deleted, and absent after first deployment;
- machine state persistence and the consequences of purge/restore.

**Step 2: Run tests and verify failure**

Run: `python3 -m unittest tests.test_secret_scan -v`

Expected: FAIL until docs, ignores, and scan implementation meet the contract.

**Step 3: Complete documentation and scan rules**

Document commands without placeholder strings that resemble real keys. Ignore `.env.gateway`, `runtime/`, `backups/`, live-test artifacts, and enrollment files. Ensure examples contain only clearly invalid values. Add `git grep`/Python scan guidance that inspects tracked content, staged diff, generated unit, container inspect, and sanitized journal output.

**Step 4: Run all static validation**

Run: `python3 -m unittest discover -s tests -v`

Expected: all tests PASS.

Run: `bash -n entrypoint.sh scripts/*.sh && git diff --check`

Expected: PASS with no shell syntax or whitespace errors.

Run: `git ls-files | grep -E '(^|/)(runtime|backups)/|\.env\.gateway$|preauth|authkey'`

Expected: no secret/runtime file matches; source filenames containing generic helper terms must be reviewed and explicitly allowlisted by `tests/test_secret_scan.py`.

**Step 5: Commit**

```bash
git add .env.gateway.example .gitignore README.md tests/test_secret_scan.py
git commit -m "docs: add gateway operations and secret checks"
```

### Task 10: Deploy and prove persistence on rootless Podman 4.9.3

**Files:**
- Modify only if a test exposes a defect: files introduced in Tasks 1-9
- Do not commit: `.env.gateway`, `runtime/`, backups, generated user units, or live logs

**Step 1: Establish a pre-deployment baseline**

Run and save a protected inventory of all existing container IDs, names, images, labels, running state, health, mounts, and user units. Confirm Podman `4.9.3`, Headscale `0.29.3`, Nginx Proxy Manager loopback `18081`, and Odoo loopback `18069`. Record the existing Matter Server resources but do not alter them.

Expected: prerequisites pass and unrelated/Matter resources remain untouched.

**Step 2: Deploy twice to prove idempotence**

Create mode-600 `.env.gateway`, then run:

```bash
scripts/deploy.sh
scripts/deploy.sh
```

Expected: first run creates at most one five-minute key and revokes/deletes it; second run creates none. Both runs finish green, the same Headscale node ID and state volume are used, and no enrollment file/key remains.

**Step 3: Verify user-systemd and security posture**

Run:

```bash
scripts/verify.sh
systemctl --user is-enabled woow-tailscale-gateway.service
systemctl --user is-active woow-tailscale-gateway.service
```

Expected: PASS/enabled/active. Inspect the steady container and journal to prove host/userspace mode, exact Serve state, no web/Caddy/key, exact ownership, and healthy local targets. Enable linger using the host’s approved administrative procedure if it is not already enabled.

**Step 4: Prove backup, restart, restore, and identity persistence**

Run a protected cold backup, record the gateway node ID and machine-state hash without printing state, restart the gateway plus Nginx Proxy Manager and Odoo, rerun verification/live tests, then restore the same backup with explicit confirmation.

Expected: all checks pass after restart and restore; node ID and state identity remain unchanged; no new preauth key is created.

**Step 5: Run the isolated client and regression inventory**

Run:

```bash
scripts/live-test.sh
scripts/verify.sh
```

Expected: direct WireGuard ping, PeerAPI ping, and HTTP access to both tailnet ports pass; the temporary key/node/resources are gone afterward. Compare the baseline: all unrelated containers have the same IDs and health/running state, and Matter Server is still present.

**Step 6: Commit only defect fixes, if any**

If live validation required source changes, first add a reproducing test, make the minimal fix, rerun Tasks 9-10, and commit only reviewed source/test/doc files. Never use `git add -A`.

```bash
git status --short
git diff --cached --name-only
git commit -m "fix: harden live gateway lifecycle"
```

Expected: only intended tracked implementation/test/doc files are committed.

### Task 11: Permanently remove Matter Server only after every stack passes

**Files:**
- Create: `tests/test_remove_matter_server.py`
- Create: `scripts/remove-matter-server.sh`
- Modify: `README.md`

**Step 1: Write the failing irreversible-removal gate tests**

Use fake systemd/Podman/HTTP/live-test commands. The script must refuse removal unless all of these occur successfully in the same invocation, immediately before mutation:

- full local unit suite and secret scan;
- `scripts/verify.sh` for Headscale 0.29.3, gateway health/config/ownership, Nginx Proxy Manager, and Odoo;
- `scripts/live-test.sh` for direct WireGuard, PeerAPI, and both forwarded HTTP services;
- gateway/service restart followed by another `verify.sh` proving the same gateway node ID;
- a protected backup of gateway state;
- exact discovery of the Matter user unit, container `matter-server`, volume `matter-server_data`, and the immutable image ID used by that container;
- explicit literal confirmation `--confirm-permanent-matter-removal`.

Test that any failure leaves every Matter resource untouched. Test exact user-unit path/content and container/volume identity, no wildcards, image removal only by captured immutable ID, refusal if a non-Matter container uses that image/volume, and a before/after snapshot proving all unrelated containers remain running and preserve prior health.

**Step 2: Run tests and verify failure**

Run: `python3 -m unittest tests.test_remove_matter_server -v`

Expected: FAIL because the guarded removal script is absent.

**Step 3: Implement the gated permanent removal**

Implement this final order only:

1. Acquire the lifecycle lock and snapshot all containers/user units.
2. Run all static, verify, live, restart-identity, and backup gates.
3. Resolve and revalidate exact Matter resources; capture image ID before removing the container.
4. Disable and stop the exact Matter user unit, remove its exact unit file, and daemon-reload.
5. Remove container `matter-server`, exact volume `matter-server_data`, and the captured image ID.
6. Rerun gateway/Headscale/Nginx Proxy Manager/Odoo verification and compare every unrelated container against the snapshot.
7. Fail loudly with recovery diagnostics if post-removal checks fail; do not recreate Matter Server automatically because removal is explicitly permanent.

Do not allow a stale `last-verification.json` alone to open the gate. Do not implement a dry-run result that can later be replayed as approval.

**Step 4: Run all tests before any live removal**

Run: `python3 -m unittest discover -s tests -v`

Expected: all tests PASS.

Run: `bash -n entrypoint.sh scripts/*.sh && git diff --check`

Expected: PASS.

Run the repository secret scan and review `git status --short`; expected: no key/runtime/backup files are tracked or staged.

**Step 5: Commit the guarded removal implementation**

```bash
git add README.md scripts/remove-matter-server.sh tests/test_remove_matter_server.py
git commit -m "feat: gate permanent Matter Server removal"
```

**Step 6: Execute the final live gate and permanent removal**

Only after Tasks 1-10 and Step 4 are green on the target host, run:

```bash
scripts/remove-matter-server.sh --confirm-permanent-matter-removal
```

Expected: the Matter user unit/file, `matter-server` container, `matter-server_data` volume, and captured Matter image ID are absent; Headscale, gateway, Nginx Proxy Manager, Odoo, and every unrelated stack remain healthy; isolated-client resources and all enrollment keys are absent.

**Step 7: Record final evidence without secrets**

Record commit SHAs, tool versions, test summaries, gateway node ID (not machine keys), Serve status, HTTP status codes, backup path/checksum, exact removed Matter resource IDs, unrelated-container comparison, and secret-scan result in the operational change record outside this repository.

Do not commit live environment details, IP inventories, logs, inspect dumps, or backup metadata that can identify credentials or private topology.
