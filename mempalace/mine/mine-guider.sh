#!/bin/bash
set -e

GUIDER_ROOT="/Users/lukebeach/REPOS/guider/platform"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' --exclude='.rush' --exclude='rush-logs' --exclude='temp' --exclude='__blobstorage__' "$GUIDER_ROOT/apps/" "$TEMP_DIR/apps/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' --exclude='.rush' --exclude='rush-logs' --exclude='temp' "$GUIDER_ROOT/packages/" "$TEMP_DIR/packages/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' --exclude='.rush' --exclude='rush-logs' --exclude='temp' --exclude='__blobstorage__' "$GUIDER_ROOT/functions/" "$TEMP_DIR/functions/"
rsync -a --exclude='node_modules' "$GUIDER_ROOT/common/config/" "$TEMP_DIR/config/"
rsync -a --exclude='node_modules' "$GUIDER_ROOT/common/autoinstallers/" "$TEMP_DIR/autoinstallers/"
cp "$GUIDER_ROOT/rush.json" "$TEMP_DIR/rush.json" 2>/dev/null || true
cp "$GUIDER_ROOT/CLAUDE.md" "$TEMP_DIR/CLAUDE.md" 2>/dev/null || true
cp "$GUIDER_ROOT/README.md" "$TEMP_DIR/README.md" 2>/dev/null || true
rsync -a "$GUIDER_ROOT/.github/" "$TEMP_DIR/.github/" 2>/dev/null || true
rsync -a "$GUIDER_ROOT/specs/" "$TEMP_DIR/specs/" 2>/dev/null || true
rsync -a "$GUIDER_ROOT/docs/" "$TEMP_DIR/docs/" 2>/dev/null || true
cp "$GUIDER_ROOT/mempalace.yaml" "$TEMP_DIR/mempalace.yaml"

echo "Mining guider from temp dir: $TEMP_DIR"
FILE_COUNT=$(find "$TEMP_DIR" -type f | wc -l | tr -d ' ')
echo "Files to process: ~$FILE_COUNT"
echo ""

python3 -m mempalace mine "$TEMP_DIR" --wing guider
