#!/usr/bin/env bash
# Restore IPs on Docker bridges that NetworkManager stripped, and mark
# wg/docker interfaces unmanaged.
#   sudo restore-bridges.sh
set -euo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

cat > /etc/NetworkManager/conf.d/99-unmanaged-wg.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wg*;interface-name:docker*;interface-name:br-*;interface-name:veth*
EOF
systemctl reload NetworkManager

ip addr replace 172.30.0.1/24 dev dockerinfra0 2>/dev/null || true

for sock in /var/run/docker.sock /run/docker-infra.sock; do
  [[ -S $sock ]] || continue
  for id in $(docker -H "unix://$sock" network ls -q --filter driver=bridge); do
    read -r name br subnet gw < <(docker -H "unix://$sock" network inspect "$id" -f \
      '{{.Name}} {{index .Options "com.docker.network.bridge.name"}} {{range .IPAM.Config}}{{.Subnet}} {{.Gateway}}{{end}}')
    if [[ -z "$br" || "$br" == "<no value>" ]]; then br="br-${id:0:12}"; fi
    [[ "$name" == bridge && "$sock" == /var/run/docker.sock ]] && br=docker0
    if [[ -z "$gw" ]]; then echo "skip $name ($br): no gateway"; continue; fi
    ip link show "$br" >/dev/null 2>&1 || { echo "skip $name: no $br"; continue; }
    ip addr replace "$gw/${subnet#*/}" dev "$br"
    echo "ok  $sock  $name  $br  $gw/${subnet#*/}"
  done
done

echo; ip -br addr | grep -E '^(docker|br-|wg)'
