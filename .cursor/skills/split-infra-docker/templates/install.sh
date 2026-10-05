#!/usr/bin/env bash
# Install two-daemon Docker + optional GitLab migrate. Idempotent. Root only.
# Requires $INFRA_ROOT/bootstrap/site.env (written by the skill / render.py).
set -euo pipefail

BOOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$BOOT/site.env"

INFRA_ROOT="${INFRA_ROOT:?}"
DATA_MOUNT="${DATA_MOUNT:?}"
ADMIN_USER="${ADMIN_USER:?}"
ADMIN_GROUP="${ADMIN_GROUP:?}"
FSTAB_UUID="${FSTAB_UUID:-}"
GITLAB_SRC="${GITLAB_SRC:-}"
GITLAB_IMAGE="${GITLAB_IMAGE:-gitlab/gitlab-ce:19.4.0-ce.0}"
MIGRATE_GITLAB="${MIGRATE_GITLAB:-0}"
START_MINIO="${START_MINIO:-0}"
START_LANGFUSE="${START_LANGFUSE:-0}"
START_LITELLM="${START_LITELLM:-0}"
DEV_DOCKER_HOST="${DEV_DOCKER_HOST:-unix:///var/run/docker.sock}"
INFRA_DOCKER_HOST="${INFRA_DOCKER_HOST:-unix:///run/docker-infra.sock}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }

persist_disk() {
  [[ -n "$FSTAB_UUID" ]] || { echo "skip fstab (FSTAB_UUID empty)"; return 0; }
  log "Persist ${DATA_MOUNT} in fstab"
  mkdir -p "$DATA_MOUNT"
  local line="UUID=${FSTAB_UUID} ${DATA_MOUNT} ext4 defaults,nofail,x-systemd.device-timeout=10 0 2"
  if grep -q "$FSTAB_UUID" /etc/fstab; then
    echo "fstab already has this UUID"
  else
    printf '\n# Infra data disk\n%s\n' "$line" >> /etc/fstab
  fi
  systemctl daemon-reload
  findmnt "$DATA_MOUNT" >/dev/null || mount "$DATA_MOUNT"
}

layout_dirs() {
  log "Layout ${INFRA_ROOT} (700 ${ADMIN_USER})"
  rm -rf "$INFRA_ROOT/shared"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$INFRA_ROOT"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" \
    "$INFRA_ROOT/bootstrap" "$INFRA_ROOT/minio" "$INFRA_ROOT/langfuse" "$INFRA_ROOT/litellm"
  install -d -m 710 -o root -g root "$INFRA_ROOT/docker" "$INFRA_ROOT/containerd"
  install -d -m 755 -o "$ADMIN_USER" -g "$ADMIN_GROUP" \
    "$INFRA_ROOT/minio/data" \
    "$INFRA_ROOT/langfuse/data/postgres" \
    "$INFRA_ROOT/langfuse/data/redis" \
    "$INFRA_ROOT/langfuse/data/clickhouse" \
    "$INFRA_ROOT/langfuse/data/clickhouse-logs" \
    "$INFRA_ROOT/litellm/data/postgres"
  chmod 700 "$INFRA_ROOT"
  chown "$ADMIN_USER:$ADMIN_GROUP" "$INFRA_ROOT"
}

install_group() {
  log "Group docker-infra"
  getent group docker-infra >/dev/null || groupadd --system docker-infra
  usermod -aG docker-infra "$ADMIN_USER"
}

install_units() {
  log "Install systemd units"
  install -d -m 755 /etc/docker /etc/containerd /etc/systemd/system/docker.service.d \
    /usr/local/sbin /usr/local/bin /etc/profile.d
  install -m 644 "$BOOT/daemon-infra.json" /etc/docker/daemon-infra.json
  install -m 644 "$BOOT/containerd-infra.toml" /etc/containerd/config-infra.toml
  install -m 644 "$BOOT/containerd-infra.service" /etc/systemd/system/containerd-infra.service
  install -m 644 "$BOOT/docker-infra.service" /etc/systemd/system/docker-infra.service
  install -m 644 "$BOOT/gitlab-infra.service" /etc/systemd/system/gitlab-infra.service
  install -m 644 "$BOOT/minio-infra.service" /etc/systemd/system/minio-infra.service
  install -m 644 "$BOOT/langfuse-infra.service" /etc/systemd/system/langfuse-infra.service
  install -m 644 "$BOOT/litellm-infra.service" /etc/systemd/system/litellm-infra.service
  install -m 644 "$BOOT/10-dev.conf" /etc/systemd/system/docker.service.d/10-dev.conf
  install -m 755 "$BOOT/docker-infra-post.sh" /usr/local/sbin/docker-infra-post.sh
  install -m 755 "$BOOT/docker-infra-bridge.sh" /usr/local/sbin/docker-infra-bridge.sh
  install -m 755 "$BOOT/docker-infra.wrapper" /usr/local/bin/docker-infra
  install -m 755 "$BOOT/backup.sh" /usr/local/sbin/backup-infra.sh
  install -m 644 "$BOOT/docker-split.sh" /etc/profile.d/docker-split.sh
  ln -sfn /usr/lib/systemd/system/docker.service /etc/systemd/system/docker-dev.service
  systemctl daemon-reload
  systemctl enable containerd-infra.service docker-infra.service
}

start_infra_daemon() {
  log "Start containerd-infra + docker-infra (do not restart docker.service)"
  systemctl reset-failed docker-infra.service containerd-infra.service || true
  systemctl enable --now containerd-infra.service
  systemctl enable --now docker-infra.service
  for _ in $(seq 1 30); do
    docker -H "$INFRA_DOCKER_HOST" info >/dev/null 2>&1 && break
    sleep 1
  done
  docker -H "$INFRA_DOCKER_HOST" info | grep -E 'Docker Root Dir|Server Version'
  docker -H "$INFRA_DOCKER_HOST" network inspect infra >/dev/null 2>&1 || \
    docker -H "$INFRA_DOCKER_HOST" network create --driver bridge infra
  echo "DEV containers:"
  docker -H "$DEV_DOCKER_HOST" ps --format 'table {{.Names}}\t{{.Status}}'
}

migrate_gitlab() {
  [[ "$MIGRATE_GITLAB" == "1" ]] || { echo "skip GitLab migrate"; return 0; }
  log "Migrate GitLab DEV -> infra"
  local dst="$INFRA_ROOT/gitlab"

  if docker -H "$INFRA_DOCKER_HOST" ps -a --format '{{.Names}}' | grep -qx gitlab; then
    echo "GitLab already on infra daemon"
    systemctl enable gitlab-infra.service
    systemctl start gitlab-infra.service
    return 0
  fi

  docker -H "$DEV_DOCKER_HOST" image inspect "$GITLAB_IMAGE" >/dev/null
  log "Load GitLab image into infra daemon"
  docker -H "$DEV_DOCKER_HOST" save "$GITLAB_IMAGE" | docker -H "$INFRA_DOCKER_HOST" load

  if docker -H "$DEV_DOCKER_HOST" ps -a --format '{{.Names}}' | grep -qx gitlab; then
    docker -H "$DEV_DOCKER_HOST" update --restart=no gitlab >/dev/null
    docker -H "$DEV_DOCKER_HOST" stop gitlab
    docker -H "$DEV_DOCKER_HOST" rm gitlab
  fi

  if [[ -n "$GITLAB_SRC" && -d "$GITLAB_SRC" && ! -e "$dst" ]]; then
    log "Move $GITLAB_SRC -> $dst"
    mv "$GITLAB_SRC" "$dst"
  elif [[ -d "$dst" ]]; then
    echo "Using existing $dst"
  else
    echo "GitLab data missing (GITLAB_SRC=$GITLAB_SRC dst=$dst)" >&2
    exit 1
  fi
  chown "$ADMIN_USER:$ADMIN_GROUP" "$dst" "$dst/docker-compose.yml" 2>/dev/null || true
  chmod 700 "$INFRA_ROOT"
  systemctl enable gitlab-infra.service
  systemctl start gitlab-infra.service
  docker -H "$INFRA_DOCKER_HOST" ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

start_optional_apps() {
  [[ "$START_MINIO" == "1" ]] && systemctl enable --now minio-infra.service
  [[ "$START_LANGFUSE" == "1" ]] && systemctl enable --now langfuse-infra.service
  [[ "$START_LITELLM" == "1" ]] && systemctl enable --now litellm-infra.service
  true
}

admin_cli() {
  log "Docker contexts for ${ADMIN_USER}"
  local home
  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  sudo -u "$ADMIN_USER" -H docker context inspect infra >/dev/null 2>&1 || \
    sudo -u "$ADMIN_USER" -H docker context create infra --docker "host=${INFRA_DOCKER_HOST}" || true
  sudo -u "$ADMIN_USER" -H docker context inspect dev >/dev/null 2>&1 || \
    sudo -u "$ADMIN_USER" -H docker context create dev --docker "host=${DEV_DOCKER_HOST}" || true
  local f="${home}/.bash_aliases"
  touch "$f"
  chown "$ADMIN_USER:$ADMIN_GROUP" "$f"
  if ! grep -q 'docker-infra' "$f" 2>/dev/null; then
    cat >> "$f" <<'EOF'

# Split Docker: default `docker` = shared dev; `docker-infra` = infra daemon
alias docker-infra='docker -H unix:///run/docker-infra.sock'
alias docker-dev='docker -H unix:///var/run/docker.sock'
EOF
    chown "$ADMIN_USER:$ADMIN_GROUP" "$f"
  fi
}

summary() {
  chmod 700 "$INFRA_ROOT"
  chown "$ADMIN_USER:$ADMIN_GROUP" "$INFRA_ROOT"
  log "Done"
  cat <<EOF
Infra:          $INFRA_ROOT (700 ${ADMIN_USER})
Infra daemon:   docker-infra.service  socket /run/docker-infra.sock
Dev daemon:     docker.service (alias docker-dev)  socket /run/docker.sock
  docker ps        # DEV
  docker-infra ps  # INFRA
Backup: sudo /usr/local/sbin/backup-infra.sh /path/to/dest
EOF
}

persist_disk
layout_dirs
install_group
install_units
start_infra_daemon
migrate_gitlab
start_optional_apps
admin_cli
summary
