---
name: split-infra-docker
description: >-
  Splits a Linux Docker host into two dockerd processes (shared-dev vs
  admin-only infra), bind-mounts service data under a chmod-700 tree, adds
  fstab + systemd. Use when the user asks to apply the infra docker split,
  isolate infra from other docker users, set up docker-infra.service,
  /mnt/d/infra, or replay the two-daemon setup on another machine.
---

# Split infra Docker (two daemons)

Do **not** invent a new design. Copy templates from this skill, fill `site.env`,
run `install.sh` as root. Compose for MinIO/Langfuse/LiteLLM lives in the
sibling setup-* skills — this skill only installs the daemons and unit shells.

## Goal

- **DEV daemon** = existing `docker.service` + `/run/docker.sock` + group `docker`.
- **INFRA daemon** = new `dockerd` + `/run/docker-infra.sock` + group `docker-infra`.
- Data under `$INFRA_ROOT/<service>/` bind-mounts. No named volumes.
- Do **not** restart `docker.service`.

Two sockets on one `dockerd` is **wrong**. Docker 29: do **not** set both
`bridge` and `bip` (pre-create `dockerinfra0`). Do **not** point infra dockerd
at `/run/containerd/containerd.sock`.

## Workflow

```
- [ ] 1. Inspect host
- [ ] 2. Confirm site.env with user
- [ ] 3. Render templates into $INFRA_ROOT/bootstrap
- [ ] 4. Run install.sh as root
- [ ] 5. Verify two daemons
```

### 1. Inspect host

```bash
id; getent group docker
docker info | grep -E 'Server Version|Root Dir|Cgroup'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
findmnt -T / /mnt /mnt/d /data /srv 2>/dev/null; grep -vE '^#|^$' /etc/fstab
```

Note: data-disk UUID, current mount, admin username + primary group + uid/gid.

### 2. Confirm `site.env`

Ask if unclear. Write `$INFRA_ROOT/bootstrap/site.env`:

```bash
INFRA_ROOT=/mnt/d/infra
DATA_MOUNT=/mnt/d
FSTAB_UUID=                  # empty = skip fstab
ADMIN_USER=
ADMIN_GROUP=
ADMIN_UID=
ADMIN_GID=
MIGRATE_GITLAB=0
START_MINIO=0
START_LANGFUSE=0
START_LITELLM=0
```

Fleet default: `INFRA_ROOT=/mnt/d/infra`, `DATA_MOUNT=/mnt/d`, `ADMIN_USER` =
current login. Leave `START_*=0` here; the setup-* skills start the apps.

### 3. Render

Skill root = directory containing this `SKILL.md`.

```bash
python3 "<SKILL>/scripts/render.py" --site "$INFRA_ROOT/bootstrap/site.env"
```

Copies systemd/json/scripts into `$INFRA_ROOT/bootstrap`.

### 4. Root install

```bash
sudo "$INFRA_ROOT/bootstrap/install.sh"
```

If `sudo` has no TTY and the user is in group `docker`, run the same script via:

```bash
docker run --rm --privileged --pid=host --network=host alpine:latest \
  nsenter -t 1 -m -u -i -n -- /bin/bash "$INFRA_ROOT/bootstrap/install.sh"
```

Ask the user to approve that privileged call. **Never** `systemctl restart docker`.

If dockerd infra fails with `You specified -b & --bip`: templates already omit
`bip`; ensure `docker-infra-bridge.sh` is `ExecStartPre`. Then
`systemctl reset-failed docker-infra && systemctl start docker-infra` and
re-run install (idempotent).

### 5. Verify

- Two `dockerd` PIDs; infra `Docker Root Dir` = `$INFRA_ROOT/docker`
- Other users' DEV containers still Up
- Other user: `ls $INFRA_ROOT` denied; infra socket permission denied
- `$DATA_MOUNT` in fstab if `FSTAB_UUID` was set
- `docker-infra network ls` shows `infra`
- `minio-infra` / `langfuse-infra` / `litellm-infra` exist, **disabled**

```bash
docker ps                  # DEV
docker-infra ps            # INFRA
sudo /usr/local/sbin/backup-infra.sh /path/to/dest
```

Backup excludes `docker/` and `containerd/` image layers.

## After this skill

Continue with [setup-wireguard](../setup-wireguard/SKILL.md), then
[setup-minio](../setup-minio/SKILL.md).

## Pitfalls (already learned)

- `bridge` + `bip` together → dockerd 29 exits. Pre-create `dockerinfra0` at `172.30.0.1/24`.
- Infra `iptables: false` so DEV NAT is not wiped; `docker-infra-post.sh` adds scoped FORWARD/MASQUERADE; published ports use userland-proxy.
- Data-disk mount is not persistent without fstab.
- Image stores are not shared: `save | load` (or `pull`) on the infra daemon.
- NetworkManager can strip bridge IPs — [restore-bridges.sh](../setup-wireguard/templates/restore-bridges.sh).

## Templates

Do not rewrite unless the target OS cannot use them. See [templates/](templates/).
