#!/usr/bin/env bash
# Enable MinIO / Langfuse / LiteLLM public binds via WireGuard.
#   sudo $INFRA_ROOT/bootstrap/expose-public.sh
# Idempotent. VPS side: /etc/wg-forward.conf + wg-forward reload.
set -euo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

INFRA_ROOT="${INFRA_ROOT:-/mnt/d/infra}"
WG_IF=wg0
WG_ADDR=10.66.0.2
PORTS=(9000 9001 3000 4000)

log "Allow bind $WG_ADDR even if wg0 is down at boot"
echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/60-infra-wg-bind.conf
sysctl -q -p /etc/sysctl.d/60-infra-wg-bind.conf

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  log "ufw: open service ports only on $WG_IF"
  for p in "${PORTS[@]}"; do
    ufw allow in on "$WG_IF" to "$WG_ADDR" port "$p" proto tcp comment "infra public via VPS"
  done
fi

log "Enable MinIO -> Langfuse -> LiteLLM"
systemctl enable minio-infra.service langfuse-infra.service litellm-infra.service
systemctl restart minio-infra.service
systemctl restart langfuse-infra.service
systemctl restart litellm-infra.service

DOCKER_HOST=unix:///run/docker-infra.sock docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
ufw status verbose 2>/dev/null || true
