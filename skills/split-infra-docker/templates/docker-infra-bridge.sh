#!/bin/bash
# Pre-create infra bridge. dockerd 29 rejects -b together with --bip.
set -euo pipefail
BR=dockerinfra0
ip link show "$BR" >/dev/null 2>&1 || ip link add name "$BR" type bridge
if ! ip -4 addr show "$BR" | grep -q '172.30.0.1/24'; then
  ip addr add 172.30.0.1/24 dev "$BR"
fi
ip link set "$BR" up
