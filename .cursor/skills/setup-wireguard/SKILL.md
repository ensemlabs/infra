---
name: setup-wireguard
description: >-
  Sets up the WireGuard publish path from the home infra host to the VPS
  (10.66.0.0/24, UDP 51820, DNAT without MASQUERADE, connmark return path,
  wg-forward, watchdog). Use when the user asks to set up WireGuard, wg0,
  wg-forward, expose MinIO/Langfuse/LiteLLM via the VPS, or replace autossh.
---

# Setup WireGuard (home ↔ VPS)

Replay this fleet's tunnel. Do **not** invent MASQUERADE, a different subnet,
or a new forward mechanism.

**Never disable password SSH on the VPS.** Never forward VPS ports `22` or `51820`.

## Roles

| Host | WG IP | Job |
|------|-------|-----|
| VPS (`PUBLIC_HOST`) | `10.66.0.1/24` | Listen UDP 51820; DNAT public TCP → home |
| Home (infra) | `10.66.0.2/24` | Client; bind services on `10.66.0.2`; reply via table 51820 |

MTU **1380** (VPS WAN is 1472 on this fleet). Subnet `10.66.0.0/24`.

Why no MASQUERADE: home fail2ban / sshd / app logs must see the **real**
client IP. VPS only DNATs. Home marks packets that arrived on `wg0`
(`connmark 0x66`) and routes replies through `table 51820` (`Table = off`
so wg-quick does **not** steal the default route).

## Port map

File on VPS: `/etc/wg-forward.conf`. Apply: `sudo wg-forward reload`.

```
tcp 2222 2486    # home sshd (do not change home sshd unless asked)
tcp 9100 9000    # MinIO S3
tcp 9101 9001    # MinIO console
tcp 3100 3000    # Langfuse
tcp 4000 4000    # LiteLLM
```

## Workflow

```
- [ ] 1. Generate keypairs on each host (never copy private keys into git)
- [ ] 2. Install home: wg0 + NM unmanaged + ip_nonlocal_bind + watchdog
- [ ] 3. Install VPS: wg0 + ip_forward + wg-forward
- [ ] 4. Exchange public keys; bring both sides up
- [ ] 5. reload forwards; ping 10.66.0.1 / 10.66.0.2
- [ ] 6. Bind-test a service on 10.66.0.2 then curl PUBLIC_HOST
```

Ask the user for `PUBLIC_HOST`, home SSH port, and whether to keep the
default forward table. Admin SSH to VPS: `ssh vps` (key, port 22, user root).

### 1. Keys

On each host:

```bash
umask 077
mkdir -p /etc/wireguard
wg genkey | tee /etc/wireguard/home.key | wg pubkey > /etc/wireguard/home.pub    # home
wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub # VPS
```

Put **public** keys into the peer sections. Private keys stay as files;
`PostUp = wg set %i private-key ...` so the conf can be world-readable-ish
(still keep conf `600`).

### 2. Home

Copy templates, substitute `PUBLIC_HOST` and the VPS public key:

```
/etc/wireguard/wg0.conf          <- templates/home-wg0.conf
/etc/NetworkManager/conf.d/99-unmanaged-wg.conf
/etc/sysctl.d/60-infra-wg-bind.conf
/usr/local/sbin/wg-watchdog
/etc/systemd/system/wg-watchdog.service
/etc/systemd/system/wg-watchdog.timer
```

```bash
sysctl -p /etc/sysctl.d/60-infra-wg-bind.conf
systemctl reload NetworkManager
systemctl enable --now wg-quick@wg0
systemctl enable --now wg-watchdog.timer
```

`ip_nonlocal_bind=1` lets Docker publish `${WG_ADDR}:...` at boot before
`wg0` exists.

Ubuntu AppArmor on `wg-quick` forbids nft reading files — keep nft rules
**inline** in `PostUp` (already in the template).

### 3. VPS

```
/etc/wireguard/wg0.conf          <- templates/vps-wg0.conf
/etc/wg-forward.conf
/usr/local/sbin/wg-forward
/etc/systemd/system/wg-forward.service
```

```bash
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/60-wg-forward.conf
sysctl -p /etc/sysctl.d/60-wg-forward.conf
systemctl enable --now wg-quick@wg0
systemctl enable --now wg-forward.service
wg-forward reload
```

`wg-forward` writes only chains `WGF-*`. It does **not** touch Docker NAT.
It refuses VPS ports already in `ss` and reserved `22`/`51820`.

### 4–6. Verify

```bash
# home
ping -c 3 -I wg0 10.66.0.1
ip -br addr show wg0          # 10.66.0.2/24
ip rule show                  # fwmark 0x66 lookup 51820
ip route show table 51820     # default dev wg0

# VPS
wg show wg0
wg-forward list
ping -c 3 10.66.0.2
```

Then start the infra units (or [expose-public.sh](templates/expose-public.sh))
and curl `http://$PUBLIC_HOST:3100`, `:4000/health/liveliness`, `:9100`.

## Gotchas

- NetworkManager must ignore `wg*` / `docker*` / `br-*` / `veth*` or it
  strips addresses. See [restore-bridges.sh](templates/restore-bridges.sh).
- Watchdog (`wg-watchdog.timer`) restarts `wg-quick@wg0` if ping to
  `10.66.0.1` fails **and** a default route exists.
- Home is behind NAT: `PersistentKeepalive = 25` is required.
- If a public port is already bound on the VPS (nginx/docker), `wg-forward`
  refuses it — pick another VPS port; do not kill VPS services.
- Old autossh (`ssh-tunnel.service`) stays disabled. Do not re-enable.

## Templates

See [templates/](templates/). Substitute `__PUBLIC_HOST__`, `__VPS_PUB__`,
`__HOME_PUB__`, `__INFRA_ROOT__`. Never paste live private keys into these files.
