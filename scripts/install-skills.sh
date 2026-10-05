#!/usr/bin/env bash
# Install this repo's Cursor skills.
#   ./scripts/install-skills.sh              # ~/.cursor/skills/  (all projects)
#   ./scripts/install-skills.sh --project    # $PWD/.cursor/skills/ (this repo only)
#   ./scripts/install-skills.sh --project /path/to/repo
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/skills"
[[ -d "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

DEST="${HOME}/.cursor/skills"
if [[ "${1:-}" == "--project" ]]; then
  dest_root="${2:-$PWD}"
  DEST="${dest_root}/.cursor/skills"
fi

# Never install into Cursor's built-in skill tree
if [[ "$DEST" == *".cursor/skills-cursor"* ]]; then
  echo "refusing to write into ~/.cursor/skills-cursor (reserved)" >&2
  exit 1
fi

mkdir -p "$DEST"
for skill in infra-stack split-infra-docker setup-wireguard setup-minio setup-langfuse setup-litellm; do
  [[ -d "$SRC/$skill" ]] || { echo "missing skill $skill" >&2; exit 1; }
  rm -rf "$DEST/$skill"
  cp -a "$SRC/$skill" "$DEST/$skill"
  echo "installed $skill -> $DEST/$skill"
done

cat <<EOF

Done. Restart Cursor (or reload the window) so the agent picks up the skills.

Personal:  available in every project
Project:   available only in that repo

Ask the agent to apply infra-stack (or a single setup-* skill).
EOF
