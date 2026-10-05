#!/bin/bash
# wg-forward — publish VPS ports to home over WireGuard.
#
#   Config: /etc/wg-forward.conf, each line:  <tcp|udp> <vps-port> <home-port>
#
#   wg-forward reload   apply config (does not drop unrelated connections)
#   wg-forward list     show active forwards
#   wg-forward flush    remove all forward rules
#
# Rules live in WGF-* chains only. Do not touch Docker NAT.
set -euo pipefail

CONF=/etc/wg-forward.conf
STATE=/run/wg-forward.applied
WG_IF=wg0
HOME_IP=10.66.0.2
WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
RESERVED_PORTS="22 51820"

die() { echo "wg-forward: $*" >&2; exit 1; }

ensure_jump() { # table parent-chain our-chain
  iptables -w -t "$1" -N "$3" 2>/dev/null || true
  iptables -w -t "$1" -C "$2" -j "$3" 2>/dev/null || iptables -w -t "$1" -I "$2" 1 -j "$3"
}

parse_conf() {
  [ -f "$CONF" ] || { echo "wg-forward: no $CONF, nothing to forward" >&2; return 0; }
  local n=0 proto vport hport extra seen=" "
  while read -r proto vport hport extra; do
    n=$((n+1))
    [[ -z "${proto:-}" || "$proto" == \#* ]] && continue
    proto=${proto,,}
    [[ "$proto" == tcp || "$proto" == udp ]] || die "line $n: proto must be tcp or udp"
    [[ "$vport" =~ ^[0-9]+$ && "$vport" -ge 1 && "$vport" -le 65535 ]] || die "line $n: bad VPS port"
    [[ "$hport" =~ ^[0-9]+$ && "$hport" -ge 1 && "$hport" -le 65535 ]] || die "line $n: bad home port"
    [[ -z "${extra:-}" || "$extra" == \#* ]] || die "line $n: extra '$extra'"
    for r in $RESERVED_PORTS; do [ "$vport" = "$r" ] && die "line $n: port $vport is reserved on the VPS"; done
    [[ "$seen" == *" $proto/$vport "* ]] && die "line $n: duplicate $proto $vport"
    seen+="$proto/$vport "
    if ss -Hln --"$proto" "sport = :$vport" | grep -q .; then
      die "line $n: $proto $vport already in use on VPS ($(ss -Hlnp --"$proto" "sport = :$vport" | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2))"
    fi
    echo "$proto $vport $hport"
  done < "$CONF"
}

reload() {
  [ -n "$WAN_IF" ] || die "no default-route interface"
  local rules; rules=$(parse_conf)

  ensure_jump nat PREROUTING WGF-PRE
  ensure_jump nat POSTROUTING WGF-POST
  ensure_jump filter FORWARD WGF-FWD

  {
    echo "*nat"
    echo ":WGF-PRE - [0:0]"
    echo ":WGF-POST - [0:0]"
    while read -r proto vport hport; do
      [ -n "$proto" ] || continue
      echo "-A WGF-PRE -i $WAN_IF -p $proto --dport $vport -j DNAT --to-destination $HOME_IP:$hport"
    done <<< "$rules"
    echo "COMMIT"
    echo "*filter"
    echo ":WGF-FWD - [0:0]"
    echo "-A WGF-FWD -i $WG_IF -o $WAN_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    echo "-A WGF-FWD -i $WAN_IF -o $WG_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    while read -r proto vport hport; do
      [ -n "$proto" ] || continue
      echo "-A WGF-FWD -i $WAN_IF -o $WG_IF -d $HOME_IP -p $proto --dport $hport -m conntrack --ctstate DNAT -j ACCEPT"
    done <<< "$rules"
    echo "COMMIT"
  } | iptables-restore -w --noflush

  if [ -f "$STATE" ] && command -v conntrack >/dev/null; then
    while read -r proto vport hport; do
      [ -n "$proto" ] || continue
      grep -qx "$proto $vport $hport" <<< "$rules" && continue
      conntrack -D -p "$proto" --orig-port-dst "$vport" --reply-src "$HOME_IP" >/dev/null 2>&1 || true
      echo "removed: $proto $vport -> home:$hport"
    done < "$STATE"
  fi
  printf '%s\n' "$rules" > "$STATE"
  list
}

flush() {
  for c in "nat PREROUTING WGF-PRE" "nat POSTROUTING WGF-POST" "filter FORWARD WGF-FWD"; do
    set -- $c
    while iptables -w -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done
    iptables -w -t "$1" -F "$3" 2>/dev/null || true
    iptables -w -t "$1" -X "$3" 2>/dev/null || true
  done
  rm -f "$STATE"
  echo "all forward rules removed"
}

list() {
  if ! iptables -w -t nat -S WGF-PRE >/dev/null 2>&1; then echo "not applied (run: wg-forward reload)"; return; fi
  echo "Forwarding (public IP -> home $HOME_IP):"
  iptables -w -t nat -S WGF-PRE | awk '/DNAT/ {
    for (i=1;i<=NF;i++) { if ($i=="-p") p=$(i+1); if ($i=="--dport") v=$(i+1); if ($i=="--to-destination") d=$(i+1) }
    split(d, a, ":"); printf "  %s %5s -> %s\n", p, v, a[2]; n++ } END { if (!n) print "  (none)" }'
  local hs; hs=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
  if [ -z "$hs" ] || [ "$hs" = 0 ]; then echo "Tunnel: home NOT connected"
  else echo "Tunnel: last handshake $(( $(date +%s) - hs ))s ago"; fi
}

[ "$(id -u)" = 0 ] || die "run as root"
case "${1:-}" in
  reload) reload ;;
  list)   list ;;
  flush)  flush ;;
  *) echo "Usage: wg-forward {reload|list|flush}"; exit 1 ;;
esac
