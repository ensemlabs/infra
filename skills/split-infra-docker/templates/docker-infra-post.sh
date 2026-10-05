#!/bin/bash
# Socket ownership + scoped NAT/FORWARD for the infra bridge.
# iptables=false on docker-infra so it does not clobber the dev daemon rules.
set -euo pipefail

SOCK=/run/docker-infra.sock
BRIDGE=dockerinfra0
OWNER=__ADMIN_USER__
GROUP=docker-infra

for _ in $(seq 1 50); do
  [[ -S "$SOCK" ]] && break
  sleep 0.1
done

if [[ -S "$SOCK" ]]; then
  chown "${OWNER}:${GROUP}" "$SOCK"
  chmod 660 "$SOCK"
fi

for _ in $(seq 1 30); do
  ip link show "$BRIDGE" >/dev/null 2>&1 && break
  sleep 0.2
done

if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  echo "docker-infra-post: bridge $BRIDGE not up yet (ok if no containers)" >&2
  exit 0
fi

ensure() {
  local table="$1"; shift
  if [[ "$table" == "-" ]]; then
    iptables -C "$@" 2>/dev/null || iptables -I "$@"
  else
    iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -I "$@"
  fi
}

ensure - FORWARD -i "$BRIDGE" -j ACCEPT
ensure - FORWARD -o "$BRIDGE" -j ACCEPT
ensure - FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ensure nat POSTROUTING -s 172.30.0.0/24 ! -o "$BRIDGE" -j MASQUERADE
ensure nat POSTROUTING -s 172.31.0.0/16 ! -o "$BRIDGE" -j MASQUERADE
