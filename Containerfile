# Woow Tailscale — Podman image
#
# Base: official upstream tailscale/tailscale image (Alpine + tailscaled + tailscale CLI),
# pinned. We add a thin env-driven entrypoint that mirrors the HA add-on's option names,
# and (optionally) tailscale's own web UI, bound to 127.0.0.1:8088 by the Quadlet unit.
#
# scripts/install.sh builds this as localhost/woow-tailscale:<tag>, where the tag comes
# from quadlet/woow-tailscale.container (Pull=never). Build it by hand with:
#
#   podman build --format docker -t localhost/woow-tailscale:1.102.3-r1 .

ARG BASE_IMAGE=docker.io/tailscale/tailscale:v1.102.3
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

# Documentation only: the unit runs this container in the host network namespace, where
# EXPOSE and published ports play no part. 41641/udp is WireGuard direct (TS_UDP_PORT),
# 8088/tcp the opt-in `tailscale web` UI, which the unit binds to 127.0.0.1.
EXPOSE 41641/udp 8088/tcp

# NOTE: HEALTHCHECK is a no-op on OCI-format images (podman's default format), which is
# why install.sh builds with --format docker. The Quadlet unit carries the same probe as
# HealthCmd=, so the unit works either way.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD tailscale status --peers=false >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/sbin/tini", "-g", "--", "/entrypoint.sh"]

LABEL org.opencontainers.image.title="Woow Tailscale (Podman)" \
      org.opencontainers.image.description="Tailscale client packaged for rootless-friendly Podman deployment with systemd quadlet." \
      org.opencontainers.image.vendor="WoowTech" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.url="https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package" \
      org.opencontainers.image.source="https://github.com/WOOWTECH/Woow_podman_vpn_tailscale_package"
