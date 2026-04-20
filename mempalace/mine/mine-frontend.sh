#!/bin/bash
set -e

FRONTEND_ROOT="/Users/lukebeach/REPOS/Thrive/frontend"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

mkdir -p "$TEMP_DIR/apps"
mkdir -p "$TEMP_DIR/libs"

rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' --exclude='.nx' --exclude='__snapshots__' --exclude='.storybook' "$FRONTEND_ROOT/apps/learner-app/" "$TEMP_DIR/apps/learner-app/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' "$FRONTEND_ROOT/libs/ui/" "$TEMP_DIR/libs/ui/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' "$FRONTEND_ROOT/libs/kiki/" "$TEMP_DIR/libs/kiki/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' "$FRONTEND_ROOT/libs/shared-utils/" "$TEMP_DIR/libs/shared-utils/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' "$FRONTEND_ROOT/libs/content/" "$TEMP_DIR/libs/content/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' "$FRONTEND_ROOT/libs/spaces/" "$TEMP_DIR/libs/spaces/"
rsync -a --exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage' "$FRONTEND_ROOT/libs/mentorship/" "$TEMP_DIR/libs/mentorship/"
cp "$FRONTEND_ROOT/CLAUDE.md" "$TEMP_DIR/CLAUDE.md" 2>/dev/null || true
cp "$FRONTEND_ROOT/README.md" "$TEMP_DIR/README.md" 2>/dev/null || true
cp "$FRONTEND_ROOT/mempalace.yaml" "$TEMP_DIR/mempalace.yaml"

echo "Mining frontend from temp dir: $TEMP_DIR"
FILE_COUNT=$(find "$TEMP_DIR" -type f | wc -l | tr -d ' ')
echo "Files to process: ~$FILE_COUNT"
echo ""

python3 -m mempalace mine "$TEMP_DIR" --wing thrive-frontend
