# Headscale Service Gateway Design

## Goal

Extend `Woow_podman_vpn_tailscale_package` with a secure rootless Podman gateway mode that joins the local Woow Headscale control plane and exposes selected host-loopback services only to authenticated tailnet clients.

## Gateway architecture

Run the Woow Tailscale image with host networking and userspace networking. This avoids changing host routes or requiring host-level Tailscale installation while allowing the container to reach `127.0.0.1` host services. Configure declarative Tailscale Serve TCP forwards:

- tailnet port `18081` to `127.0.0.1:18081` for Nginx Proxy Manager administration;
- tailnet port `18069` to `127.0.0.1:18069` for Odoo.

Nginx Proxy Manager HTTP/HTTPS ports remain public; only its administration endpoint and Odoo use the VPN gateway.

## Enrollment and secret handling

Deployment creates a short-lived reusable Headscale pre-auth key for the existing `default` user, supplies it through a mode-`600` file, enrolls the gateway, then immediately deletes the key and clears the file. The gateway machine state persists in a project-owned volume so future restarts require no auth key. Enrollment keys must never appear in container configuration, command output, runtime files after enrollment, or logs.

## Lifecycle

Add declarative Serve forwarding support, strict environment validation, exact ownership checks, health/readiness verification, backup and restore of machine state, scoped removal, and a user-systemd unit. Disable the optional Tailscale web UI and Caddy sidecar for this deployment.

## Verification and host migration

Create an isolated temporary Tailscale client, enroll it with a separately revoked key, and prove WireGuard/PeerAPI connectivity plus HTTP access to both forwarded services. Restart the gateway and services, verify the same node identity and continued access, then delete the temporary client and node. After all new stacks pass, permanently remove Matter Server: disable and delete its user unit, container, `matter-server_data` volume, and image. Verify all unrelated containers remain healthy.
