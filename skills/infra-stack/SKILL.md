---
name: infra-stack
description: >-
  Orchestrates the full home infra stack: two Docker daemons, WireGuard
  publish via VPS, then MinIO, Langfuse, and LiteLLM. Use when the user
  asks to recreate, replay, bootstrap, or document this infra on a new
  machine, or mentions /mnt/d/infra, docker-infra, the service trio, or
  the VPS tunnel as a whole.
---

# Infra stack (orchestrator)

Do **not** invent a new topology. Apply the sibling skills in order. Skill
pack root = the directory that contains these sibling skill folders
(`skills/` in the repo; `~/.cursor/skills/` after personal install).

## Topology (this fleet)

```
Internet
   │
   ▼
VPS  PUBLIC_HOST:22 / 51820 / 2222 / 3100 / 4000 / 9100 / 9101
   │  WireGuard 10.66.0.1  (wg-forward DNAT, no MASQUERADE)
   ▼
Home wg0  10.66.0.2
   │
   ├── docker.service          DEV   /run/docker.sock      group docker
   └── docker-infra.service    INFRA /run/docker-infra.sock group docker-infra
         network `infra`
         ├── minio        127.0.0.1 + 10.66.0.2 :9000/:9001
         ├── langfuse     127.0.0.1 + 10.66.0.2 :3000
         └── litellm      127.0.0.1 + 10.66.0.2 :4000
```

Public map (VPS → home, `/etc/wg-forward.conf`):

| Public | Home | Service |
|--------|------|---------|
| tcp 2222 | 2486 | home sshd |
| tcp 9100 | 9000 | MinIO S3 |
| tcp 9101 | 9001 | MinIO console |
| tcp 3100 | 3000 | Langfuse |
| tcp 4000 | 4000 | LiteLLM |

Defaults: `INFRA_ROOT=/mnt/d/infra` (chmod 700, admin only), `DATA_MOUNT=/mnt/d`,
WG subnet `10.66.0.0/24`, MTU 1380.

## Apply order

Copy this checklist:

```
- [ ] 1. Confirm site.env with the user
- [ ] 2. split-infra-docker          daemon + dirs + units (apps stay down)
- [ ] 3. setup-wireguard             home peer + VPS forward
- [ ] 4. setup-minio
- [ ] 5. setup-langfuse              needs MinIO + matching S3 keys
- [ ] 6. setup-litellm               needs Langfuse project keys
- [ ] 7. Enable units + verify public URLs
```

Read and follow each skill (do not skip):

1. [split-infra-docker](../split-infra-docker/SKILL.md)
2. [setup-wireguard](../setup-wireguard/SKILL.md)
3. [setup-minio](../setup-minio/SKILL.md)
4. [setup-langfuse](../setup-langfuse/SKILL.md)
5. [setup-litellm](../setup-litellm/SKILL.md)

## Shared `site.env`

Write `$INFRA_ROOT/bootstrap/site.env` once. Ask if any value is unclear.

```bash
INFRA_ROOT=/mnt/d/infra
DATA_MOUNT=/mnt/d
FSTAB_UUID=                 # blkid of DATA_MOUNT; empty = skip fstab
ADMIN_USER=                 # only this user uses the infra socket
ADMIN_GROUP=
ADMIN_UID=
ADMIN_GID=
PUBLIC_HOST=                # VPS public IPv4
WG_IF=wg0
WG_ADDR=10.66.0.2
WG_SERVER_ADDR=10.66.0.1
WG_SUBNET=10.66.0.0/24
WG_LISTEN=51820
BIND_ADDR=127.0.0.1
LANGFUSE_PUBLIC_PORT=3100
LITELLM_PUBLIC_PORT=4000
S3_PUBLIC_PORT=9100
CONSOLE_PUBLIC_PORT=9101
HOME_SSH_PORT=2486
VPS_SSH_FORWARD=2222
```

Fill `ADMIN_*` from `id -u`, `id -gn`, `id -g` of the admin login.

## Secrets

Generate new secrets on a new host. **Never** copy live `.env` into a skill
or commit. Mode `600`, owner `ADMIN_USER`. Cross-file matches:

- `minio/.env` `LANGFUSE_S3_*` = `langfuse/.env` `LANGFUSE_S3_*`
- `langfuse/.env` `LANGFUSE_PUBLIC_KEY` + `LANGFUSE_SECRET_KEY` = `litellm/.env`
- `PUBLIC_HOST`, `WG_ADDR`, `BIND_ADDR` identical in all three `.env`

```bash
openssl rand -hex 16          # most passwords
openssl rand -hex 32          # 64-hex keys (Langfuse encryption / NEXTAUTH)
printf 'sk-%s\n' "$(openssl rand -hex 24)"
```

## Hard rules

- Two `dockerd` processes. Two sockets on one daemon is wrong.
- Do **not** `systemctl restart docker`.
- Do **not** disable password SSH on the VPS.
- Do **not** MASQUERADE WG forwards (home must see the real client IP).
- Do **not** start Langfuse before MinIO is healthy.
- Bind-mounts only. No named volumes. No top-level `shared/` or `postgres/`.
- GitLab is **not** part of the current stack (removed). Skip unless the user asks.

## CLI after install

```bash
docker ps                  # DEV
docker-infra ps            # INFRA
sudo systemctl start minio-infra langfuse-infra litellm-infra
sudo wg-forward list       # on VPS
ssh -T git@github.com      # unrelated; do not mix keys
```
