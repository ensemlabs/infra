#!/bin/bash
# Restart the tunnel if 10.66.0.1 is unreachable via wg0 while a WAN default route exists.
IF=wg0; PEER_IP=10.66.0.1; ADDR=10.66.0.2
systemctl is-enabled --quiet wg-quick@$IF || exit 0
restart() { logger -t wg-watchdog "$1 -> restart $IF"; systemctl restart wg-quick@$IF; exit; }
ip link show "$IF" >/dev/null 2>&1 || restart "$IF missing"
ip -4 addr show dev "$IF" | grep -q "inet $ADDR/" || restart "$IF lost $ADDR"
ping -c 5 -i 2 -W 2 -I "$IF" "$PEER_IP" >/dev/null 2>&1 && exit 0
ip -4 route show default | grep -q . || exit 0
restart "cannot ping $PEER_IP via tunnel"
