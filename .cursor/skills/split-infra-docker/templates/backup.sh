#!/usr/bin/env bash
# Backup bind-mount data + bootstrap (not image layers).
set -euo pipefail
SRC=__INFRA_ROOT__
DEST=${1:-}

if [[ -z "$DEST" ]]; then
  echo "Usage: $0 /path/to/backup-dir" >&2
  exit 1
fi
mkdir -p "$DEST"
rsync -aHAX --numeric-ids \
  --exclude docker/ \
  --exclude containerd/ \
  --exclude '*/logs/' \
  "$SRC/" "$DEST/"
echo "Backup written to $DEST"
echo "Restore: rsync -aHAX --numeric-ids DEST/ ${SRC}/"
echo "Then re-run the split-infra-docker skill with MIGRATE_GITLAB=0."
