# Infra

Playbook for rebuilding the home infrastructure stack: two Docker daemons,
a WireGuard path through a VPS, then MinIO, Langfuse, and LiteLLM.

This repository holds Cursor skills and config templates. It does not hold
live `.env` files, WireGuard private keys, Docker image stores, or service
data. On a running host the live tree is `$INFRA_ROOT` (default `/mnt/d/infra`,
mode `700`). The git checkout and the live tree may share that directory;
`.gitignore` keeps volumes and secrets out of commits.

## Architecture

```text
Internet
   │
   ▼
VPS  PUBLIC_HOST
     WireGuard 10.66.0.1   UDP 51820
     wg-forward DNAT (no MASQUERADE)
   │
   ▼
Home wg0  10.66.0.2
     docker.service         DEV    /run/docker.sock        group docker
     docker-infra.service   INFRA  /run/docker-infra.sock  group docker-infra
          network infra
          ├── minio      127.0.0.1 + 10.66.0.2 :9000 / :9001
          ├── langfuse   127.0.0.1 + 10.66.0.2 :3000
          └── litellm    127.0.0.1 + 10.66.0.2 :4000
```

Public port map on the VPS (`/etc/wg-forward.conf`):

| VPS | Home | Service |
| --- | --- | --- |
| tcp 2222 | 2486 | Home SSH |
| tcp 9100 | 9000 | MinIO S3 API |
| tcp 9101 | 9001 | MinIO console |
| tcp 3100 | 3000 | Langfuse |
| tcp 4000 | 4000 | LiteLLM |

## Prerequisites

- Linux host with systemd, Docker, and a data disk mounted at `/mnt/d` (or the path you set in `site.env`)
- A VPS you can SSH to as root, with password login left enabled
- `wireguard-tools`, `iptables`, and `nft` on both ends of the tunnel
- Cursor, if you want the agent to apply the skills

## Install the skills

Cursor loads skills from `~/.cursor/skills/` or from a project's `.cursor/skills/`.
Files under `skills/` in this repository are the source pack; they are not active until installed.

Personal install (available in every project):

```bash
git clone git@github.com:COCOTECH-Labs/infra.git
cd infra
./scripts/install-skills.sh
```

Project install (available only in that repository):

```bash
./scripts/install-skills.sh --project /path/to/your-repo
```

Manual copy:

```bash
mkdir -p ~/.cursor/skills
cp -a skills/* ~/.cursor/skills/
```

Leave `~/.cursor/skills-cursor/` alone. That directory is reserved for Cursor's built-in skills.

Reload the Cursor window after install. Then ask the agent to apply `infra-stack`.
It reads the child skills in order, copies templates, fills `site.env`, and
generates new secrets on a new host.

## Skills

Apply them in this order: **docker split → WireGuard → MinIO → Langfuse → LiteLLM**.

| Skill | Role |
| --- | --- |
| [`infra-stack`](skills/infra-stack/SKILL.md) | Order, shared `site.env`, hard rules |
| [`split-infra-docker`](skills/split-infra-docker/SKILL.md) | `docker` (DEV) and `docker-infra` (INFRA) |
| [`setup-wireguard`](skills/setup-wireguard/SKILL.md) | Home `10.66.0.2` to VPS `10.66.0.1`, `wg-forward` |
| [`setup-minio`](skills/setup-minio/SKILL.md) | Private buckets and per-app access keys |
| [`setup-langfuse`](skills/setup-langfuse/SKILL.md) | Tracing, with its own Postgres, Redis, and ClickHouse |
| [`setup-litellm`](skills/setup-litellm/SKILL.md) | LLM proxy, `/ui`, traces to Langfuse |

Each skill ships templates under `skills/<name>/templates/`.

## Day-to-day commands

On the home host:

```bash
docker ps                  # DEV daemon
docker-infra ps            # INFRA daemon
sudo systemctl start minio-infra langfuse-infra litellm-infra
sudo /usr/local/sbin/backup-infra.sh /path/to/dest
```

On the VPS (`ssh vps`, root, key `~/.ssh/id_ed25519_vps_admin`, port 22):

```bash
sudo wg-forward {reload|list|flush}
```

## Rules

- Run two `dockerd` processes. Two sockets on one daemon is the wrong layout.
- Leave `docker.service` running. Restart `docker-infra` when the infra daemon must restart.
- Keep password SSH enabled on the VPS.
- Forward with DNAT only. Home must see the real client IP (`connmark 0x66`, routing table `51820`, `Table = off`).
- Start MinIO before Langfuse, and Langfuse before LiteLLM.
- Use bind mounts. Langfuse and LiteLLM each have their own Postgres.
- On Docker 29, pre-create bridge `dockerinfra0`. Do not set both `bridge` and `bip`.
- Point the infra daemon at its own containerd socket, `/run/containerd-infra/containerd.sock`.
- Generate secrets with `openssl rand`. Keep `LANGFUSE_S3_*` identical in MinIO and Langfuse, and copy the Langfuse project keys into LiteLLM.
- Leave `LITELLM_SALT_KEY` and Langfuse `ENCRYPTION_KEY` unchanged after the first start.

## Repository layout

```text
AGENTS.md                  instructions for the agent
README.md                  this file
scripts/install-skills.sh  copy skills into Cursor
skills/<name>/SKILL.md     one skill
skills/<name>/templates/   compose, systemd, WireGuard, env examples
```

Tracked paths are `AGENTS.md`, `README.md`, `skills/`, `scripts/`, and `.gitignore`. Service data, `.env`, private keys, `docker/`, and `containerd/` stay local.

Agent-facing detail is in [AGENTS.md](AGENTS.md).
