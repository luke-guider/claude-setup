#!/bin/bash
set -euo pipefail

# Tarball snapshot of mempalace palace. Timestamped, retained for SNAPSHOT_RETENTION_DAYS.

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

if [ ! -d "$BACKUP_SHARE" ]; then
  echo "ERROR: BACKUP_SHARE '$BACKUP_SHARE' not mounted"
  exit 1
fi

DEST="$BACKUP_SHARE/claude-backup/snapshots"
LOG="$BACKUP_SHARE/claude-backup/backup.log"
TS=$(date +%Y-%m-%d-%H%M%S)
SNAPSHOT="$DEST/$TS.tar.gz"

mkdir -p "$DEST"

echo "$(date -Iseconds) snapshot start: $TS" >> "$LOG"
echo "Creating snapshot: $SNAPSHOT..."

START=$(date +%s)

tar -czf "$SNAPSHOT" \
  --exclude='.mempalace/hook_state' \
  --exclude='.mempalace/hooks' \
  --exclude='.mempalace/mine-*.sh' \
  -C "$HOME" .mempalace

END=$(date +%s)
DURATION=$((END - START))
SIZE=$(du -h "$SNAPSHOT" | cut -f1)

echo "$(date -Iseconds) snapshot complete: $TS ($SIZE, ${DURATION}s)" >> "$LOG"
echo "Snapshot created: $SNAPSHOT"
echo "Duration: ${DURATION}s | Size: $SIZE"

# Prune old snapshots
PRUNE_DAYS="${SNAPSHOT_RETENTION_DAYS:-30}"
PRUNED=$(find "$DEST" -name "*.tar.gz" -mtime +"$PRUNE_DAYS" -print -delete | wc -l | tr -d ' ')
if [ "$PRUNED" -gt 0 ]; then
  echo "Pruned $PRUNED snapshots older than $PRUNE_DAYS days"
  echo "$(date -Iseconds) pruned $PRUNED old snapshots" >> "$LOG"
fi
