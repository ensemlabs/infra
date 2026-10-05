---
name: setup-langfuse
description: >-
  Installs Langfuse v3 on the infra Docker daemon with its own Postgres,
  Redis, ClickHouse, MinIO event/media/export buckets, and dual bind on
  localhost plus WireGuard. Use when the user asks to set up Langfuse,
  langfuse-infra, tracing for LiteLLM, or AgentCAD project keys.
---

# Setup Langfuse (infra)

Requires MinIO healthy on network `infra` and matching `LANGFUSE_S3_*`.
Public URL needs WireGuard + VPS `3100 → 3000`.

Do not share Postgres with LiteLLM. Redis/ClickHouse live only under
`$INFRA_ROOT/langfuse/data/`.

## Layout

```
$INFRA_ROOT/langfuse/
  docker-compose.yml
  .env                 # mode 600
  data/{postgres,redis,clickhouse,clickhouse-logs}
```

Images: `langfuse/langfuse:3`, `langfuse/langfuse-worker:3`,
`postgres:17-alpine`, `redis:7-alpine`, `clickhouse/clickhouse-server:25.8`.

ClickHouse runs as `HOST_UID:HOST_GID` (same reason as MinIO).

Init org/project (first boot only, via env):

- org/project id `agentcad`, org name `AgentCAD`
- signup disabled (`AUTH_DISABLE_SIGNUP=true`)
- admin from `LANGFUSE_ADMIN_EMAIL` / `LANGFUSE_ADMIN_PASSWORD`

## S3 endpoints (easy to get wrong)

| Use | Endpoint |
|-----|----------|
| Event upload (server → MinIO) | `http://minio:9000` |
| Batch export (server → MinIO) | `http://minio:9000` |
| Media upload (browser presign) | `http://${PUBLIC_HOST}:${S3_PUBLIC_PORT}` |
| Batch export **external** (browser download) | `http://${PUBLIC_HOST}:${S3_PUBLIC_PORT}` |

Use the dedicated Langfuse S3 user, **not** MinIO root.

`NEXTAUTH_URL` = `http://${PUBLIC_HOST}:${LANGFUSE_PUBLIC_PORT}` (VPS 3100).

## Workflow

```
- [ ] 1. Copy compose + unit
- [ ] 2. Write .env mode 600; copy LANGFUSE_S3_* from minio/.env
- [ ] 3. mkdir data dirs, chown admin
- [ ] 4. systemctl enable --now langfuse-infra
- [ ] 5. Wait for web healthy; copy project keys into litellm/.env
```

### 1–3. Files

```bash
install -d -m 755 -o "$ADMIN_USER" -g "$ADMIN_GROUP" \
  "$INFRA_ROOT/langfuse/data/postgres" \
  "$INFRA_ROOT/langfuse/data/redis" \
  "$INFRA_ROOT/langfuse/data/clickhouse" \
  "$INFRA_ROOT/langfuse/data/clickhouse-logs"
install -m 644 "<SKILL>/templates/docker-compose.yml" "$INFRA_ROOT/langfuse/docker-compose.yml"
```

Copy [templates/env.example](templates/env.example) → `.env`, `chmod 600`.

```bash
openssl rand -hex 16                                    # POSTGRES/REDIS/CLICKHOUSE/ADMIN pass
openssl rand -hex 16                                    # SALT
openssl rand -hex 32                                    # ENCRYPTION_KEY and NEXTAUTH_SECRET (64 hex)
printf 'pk-lf-%s\n' "$(openssl rand -hex 12)"
printf 'sk-lf-%s\n' "$(openssl rand -hex 16)"
```

`ENCRYPTION_KEY` must be 64 hex chars. Changing it after first start
orphans existing data.

Copy `LANGFUSE_PUBLIC_KEY` + `LANGFUSE_SECRET_KEY` into `litellm/.env`.

### 4–5. Start + verify

```bash
sudo systemctl enable --now langfuse-infra
docker-infra ps
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/api/public/health
```

Local UI: `http://127.0.0.1:3000`. Public: `http://${PUBLIC_HOST}:3100`.
Login = `LANGFUSE_ADMIN_EMAIL`. Team users are created in the UI (or a
follow-up script); do not bake extra passwords into compose.

`langfuse-infra.service` `Requires=minio-infra.service`.

## Pitfalls

- Starting Langfuse before MinIO → worker crash-loop on S3.
- Media/export links that use `http://minio:9000` break the browser.
- ClickHouse permission errors → wrong container uid vs `./data/clickhouse`.
- `NEXTAUTH_URL` must be the URL users type; mismatch breaks login cookies.

## Next

[setup-litellm](../setup-litellm/SKILL.md)
