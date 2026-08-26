# Woow Tailscale — Podman image
#
# Base: official upstream tailscale/tailscale image (Alpine + tailscaled + tailscale CLI).
# We add a thin env-driven entrypoint that mirrors the HA add-on's option names,
# and (optionally) tailscale's own web UI on :8088 for a reverse-proxy sidecar.

ARG BASE_IMAGE=docker.io/tailscale/tailscale:stable
FROM ${BASE_IMAGE}

# Small extras used by entrypoint / userspace scripts:
#   iptables/ip6tables  → for advertise-routes (subnet router)
#   iproute2            → ip commands (protect-subnet-routes)
#   ca-certificates     → curl / login_server https
#   bash + jq + tini    → entrypoint dependencies
RUN apk add --no-cache \
      bash \
      ca-certificates \
      iproute2 \
      iptables \
      ip6tables \
      jq \
      tini

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Container state lives at /var/lib/tailscale (bind-mount a volume here).
VOLUME ["/var/lib/tailscale"]

# 41641/udp = WireGuard direct; 8088/tcp = tailscale web UI (opt-in via TS_WEB_UI).
EXPOSE 41641/udp 8088/tcp

# NOTE: HEALTHCHECK is a no-op on OCI-format images (podman default).
# The equivalent liveness probe lives in compose.yml AND the quadlet (HealthCmd=),
# both of which honour it. To bake this into the image itself use:
#   podman build --format docker -t localhost/woow-tailscale:latest .
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD tailscale status --peers=false >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/sbin/tini", "-g", "--", "/entrypoint.sh"]

LABEL org.opencontainers.image.title="Woow Tailscale (Podman)" \
      org.opencontainers.image.description="Tailscale client packaged for rootless-friendly Podman deployment with systemd quadlet." \
      org.opencontainers.image.vendor="WoowTech" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.url="https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package" \
      org.opencontainers.image.source="https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package"
