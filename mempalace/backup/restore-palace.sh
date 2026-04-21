#!/bin/bash
set -euo pipefail

# Restore mempalace palace from local-share backup.
# Reads from $BACKUP_SHARE/claude-backup/mempalace/ by default.
# Pass a tarball path as arg to restore from snapshot instead.

CONFIG="$HOME/.claude-setup/config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: $CONFIG not found. Run install.sh first."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

if [ -n "${1:-}" ]; then
  # Restore from tarball snapshot
  SNAPSHOT="$1"
  if [ ! -f "$SNAPSHOT" ]; then
    echo "ERROR: Snapshot file not found: $SNAPSHOT"
    exit 1
  fi

  echo "Restoring from tarball: $SNAPSHOT"
  echo "This will OVERWRITE $HOME/.mempalace/palace/ and knowledge_graph.sqlite3"
  read -rp "Continue? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

  tar -xzf "$SNAPSHOT" -C "$HOME"
  echo "Restored from $SNAPSHOT"
else
  # Restore from rsync mirror
  if [ -z "${BACKUP_SHARE:-}" ]; then
    echo "ERROR: BACKUP_SHARE not set in $CONFIG"
    exit 1
  fi

  SRC="$BACKUP_SHARE/claude-backup/mempalace"
  if [ ! -d "$SRC" ]; then
    echo "ERROR: No backup mirror found at $SRC"
    echo "Either run backup first, or pass a snapshot tarball:"
    echo "  ./restore-palace.sh $BACKUP_SHARE/claude-backup/snapshots/<timestamp>.tar.gz"
    exit 1
  fi

  echo "Restoring from mirror: $SRC"
  echo "This will OVERWRITE non-excluded files in $HOME/.mempalace/"
  read -rp "Continue? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

  rsync -a \
    --exclude='hook_state/' \
    --exclude='hooks/' \
    --exclude='mine-*.sh' \
    "$SRC/" "$HOME/.mempalace/"

  echo "Palace restored from $SRC"
fi

echo ""
echo "Verify with: python3 -m mempalace status"
