#!/bin/bash
set -euo pipefail

# Incremental rsync backup of mempalace palace to a local share.
# Fast when palace unchanged (checksums only). Slower after mining.

CONFIG="$HOME/.claude-setup/config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: $CONFIG not found. Run install.sh first."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

if [ -z "${BACKUP_SHARE:-}" ]; then
  echo "ERROR: BACKUP_SHARE not set in $CONFIG"
  exit 1
fi

DEST="$BACKUP_SHARE/claude-backup/mempalace"
LOG="$BACKUP_SHARE/claude-backup/backup.log"

if [ ! -d "$BACKUP_SHARE" ]; then
  echo "ERROR: BACKUP_SHARE '$BACKUP_SHARE' not mounted"
  exit 1
fi

mkdir -p "$DEST" "$(dirname "$LOG")"

START=$(date +%s)
echo "$(date -Iseconds) rsync start" >> "$LOG"

rsync -a --delete \
  --exclude='hook_state/' \
  --exclude='hooks/' \
  --exclude='mine-*.sh' \
  "$HOME/.mempalace/" "$DEST/"

END=$(date +%s)
DURATION=$((END - START))
SIZE=$(du -sh "$DEST" | cut -f1)

echo "$(date -Iseconds) rsync complete in ${DURATION}s, total size: $SIZE" >> "$LOG"
echo "Backup complete: $DEST"
echo "Duration: ${DURATION}s | Size: $SIZE"
