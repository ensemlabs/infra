---
name: setup-minio
description: >-
  Installs MinIO on the infra Docker daemon with bind-mounted data, per-app
  access keys, private buckets, and dual bind on localhost plus WireGuard.
  Use when the user asks to set up MinIO, S3 for Langfuse/CAD, minio-infra,
  or buckets langfuse/agentcad/cad.
---

# Setup MinIO (infra)

Requires [split-infra-docker](../split-infra-docker/SKILL.md) already applied
(`docker-infra` up, network `infra` exists). Public publish needs
[setup-wireguard](../setup-wireguard/SKILL.md).

Copy templates from this skill. Do not invent a different image, port map, or
init policy.

## Layout

```
$INFRA_ROOT/minio/
  docker-compose.yml
  .env                 # mode 600
  data/                # bind-mount /data
```

Image: `cgr.dev/chainguard/minio:latest` + `minio-client:latest-dev` (needs `/bin/sh`).
Run server as `HOST_UID:HOST_GID` so it can write `./data` owned by the admin.

Ports:

- `${BIND_ADDR}:9000` / `:9001` — local only
- `${WG_ADDR}:9000` / `:9001` — VPS forwards 9100→9000, 9101→9001

Buckets created by `minio-init` (all private, `anonymous none`):

| Bucket | Access key env | Policy |
|--------|----------------|--------|
| `langfuse` | `LANGFUSE_S3_*` | `langfuse-rw` on that bucket only |
| `${APP_BUCKET}` (default `agentcad`) | root / unused by apps | private |
| `${CAD_BUCKET}` (default `cad`) | `CAD_S3_*` | `cad-rw` on `cad` only |

Root (`MINIO_ROOT_*`) is admin-only. Apps never use root.

## Workflow

```
- [ ] 1. Copy compose + systemd unit
- [ ] 2. Write .env mode 600 (generate secrets)
- [ ] 3. mkdir data, chown admin
- [ ] 4. systemctl enable --now minio-infra
- [ ] 5. Confirm minio-init exited 0 and buckets exist
```

### 1. Copy

Skill root = directory containing this `SKILL.md`.

```bash
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$INFRA_ROOT/minio/data"
install -m 644 "<SKILL>/templates/docker-compose.yml" "$INFRA_ROOT/minio/docker-compose.yml"
# unit is already rendered by split-infra-docker; re-copy if missing:
sudo install -m 644 "<SKILL>/templates/minio-infra.service" /etc/systemd/system/minio-infra.service
sudo systemctl daemon-reload
```

Substitute `__INFRA_ROOT__` in the unit if copying the raw template.

### 2. `.env`

Copy [templates/env.example](templates/env.example) → `$INFRA_ROOT/minio/.env`.
`chmod 600`. Generate:

```bash
openssl rand -hex 24          # MINIO_ROOT_PASSWORD (>= 8 chars; use 24+ hex)
openssl rand -hex 24          # LANGFUSE_S3_SECRET_KEY
openssl rand -hex 24          # CAD_S3_SECRET_KEY
```

`LANGFUSE_S3_*` **must** be copied into `langfuse/.env` unchanged.
`PUBLIC_HOST` / `WG_ADDR` / `BIND_ADDR` must match the other services.

### 3–5. Start + verify

```bash
sudo systemctl enable --now minio-infra
docker-infra ps
docker-infra logs minio-init
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/minio/health/live
```

Expect `minio` Up, `minio-init` Exited 0. Console locally:
`http://127.0.0.1:9001`. Public (after WireGuard):
`http://${PUBLIC_HOST}:9101` and S3 `http://${PUBLIC_HOST}:9100`.

`MINIO_BROWSER_REDIRECT_URL` must be the **public** console URL or the browser
redirects to a dead local address.

## Pitfalls

- Chainguard `minio-client:latest` has no shell — init **must** use `latest-dev`.
- If `./data` is owned by admin, container user must be that uid:gid or ClickHouse/MinIO cannot write.
- Re-running init is safe (`mb --ignore-existing`, `policy attach || true`) but
  does not rotate keys. To rotate, edit `.env` and recreate the MinIO user.
- Do not make buckets public. S3 API is on the Internet via the VPS.

## Next

[setup-langfuse](../setup-langfuse/SKILL.md)
