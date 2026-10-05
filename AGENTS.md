# AGENTS.md

This directory on a live host is `$INFRA_ROOT` (default `/mnt/d/infra`): bind-mount
data and two Docker daemons. The GitHub repo is the playbook only (`skills/`,
`README.md`, this file). It must never contain `.env`, WireGuard private keys,
Docker image stores, or `*/data/`.

Skills are **not** loaded from this repo until installed. See `README.md`
(`./scripts/install-skills.sh` → `~/.cursor/skills/`).

## What this stack is

```
Internet → VPS PUBLIC_HOST
            WireGuard 10.66.0.1   UDP 51820
            wg-forward DNAT (no MASQUERADE)
                 ↓
Home wg0 10.66.0.2
  docker.service        DEV    /run/docker.sock       group docker
  docker-infra.service  INFRA  /run/docker-infra.sock group docker-infra
       network `infra`
       ├── minio      127.0.0.1 + 10.66.0.2 :9000 / :9001
       ├── langfuse   127.0.0.1 + 10.66.0.2 :3000
       └── litellm    127.0.0.1 + 10.66.0.2 :4000
```

Public map (VPS → home), `/etc/wg-forward.conf`:

| VPS | Home | Service |
|-----|------|---------|
| tcp 2222 | 2486 | home sshd |
| tcp 9100 | 9000 | MinIO S3 |
| tcp 9101 | 9001 | MinIO console |
| tcp 3100 | 3000 | Langfuse |
| tcp 4000 | 4000 | LiteLLM |

## Skills (read these; do not invent a new design)

| Skill | Path | Does |
|-------|------|------|
| Orchestrator | `skills/infra-stack/SKILL.md` | Order, shared `site.env`, hard rules |
| Two dockerd | `skills/split-infra-docker/SKILL.md` | `docker` vs `docker-infra`, fstab, units |
| Tunnel | `skills/setup-wireguard/SKILL.md` | Home + VPS + `wg-forward` + watchdog |
| Object store | `skills/setup-minio/SKILL.md` | Buckets + per-app keys |
| Tracing | `skills/setup-langfuse/SKILL.md` | Own Postgres/Redis/ClickHouse |
| LLM gateway | `skills/setup-litellm/SKILL.md` | Own Postgres, `/ui`, Langfuse traces |

Apply order: **docker split → WireGuard → MinIO → Langfuse → LiteLLM**.

When the user says “rebuild / replay / setup this infra”, start at `infra-stack`.
Copy templates from the skill; fill `site.env`; generate new secrets on a new host.

## Hard rules

- Two `dockerd` processes. Two sockets on one daemon is wrong.
- Never `systemctl restart docker` (the DEV daemon).
- Never disable password SSH on the VPS.
- Never MASQUERADE WireGuard forwards. Home must see the real client IP
  (`connmark 0x66` + routing table `51820`, `Table = off`).
- Never start Langfuse before MinIO is healthy; never start LiteLLM before Langfuse.
- Bind-mounts only. No named volumes. No top-level `shared/` or `postgres/`.
- Langfuse and LiteLLM each have **their own** Postgres.
- Docker 29: do not set both `bridge` and `bip`. Pre-create `dockerinfra0`.
- Infra dockerd uses its own containerd (`/run/containerd-infra/containerd.sock`).
- GitLab is not in the current stack unless the user asks.
- Do not commit secrets. `.env` is mode `600`, local only.

## CLI on a live host

```bash
docker ps           # DEV
docker-infra ps     # INFRA
sudo systemctl start minio-infra langfuse-infra litellm-infra
sudo /usr/local/sbin/backup-infra.sh /path/to/dest
```

On the VPS (`ssh vps`, root, key `~/.ssh/id_ed25519_vps_admin`, port 22):

```bash
sudo wg-forward {reload|list|flush}
```

## Secrets that must match across files

Generate with `openssl rand`; never copy live values into git.

- `minio/.env` `LANGFUSE_S3_*` = `langfuse/.env` `LANGFUSE_S3_*`
- `langfuse/.env` `LANGFUSE_PUBLIC_KEY` + `LANGFUSE_SECRET_KEY` = `litellm/.env`
- `PUBLIC_HOST`, `WG_ADDR`, `BIND_ADDR` identical in all three `.env`
- `LITELLM_SALT_KEY` and Langfuse `ENCRYPTION_KEY` must not be rotated after first start

## Git

This repo is deny-by-default (`.gitignore` ignores the live tree). Only add:

- `AGENTS.md`, `README.md`
- `skills/**`, `scripts/**`
- `.gitignore`

Do not add `.cursor/` to git.

If asked to commit: refuse `.env`, `*.key`, `wg0.conf` with private keys, `docker/`,
`containerd/`, and any `data/` directory.
