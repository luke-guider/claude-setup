#!/bin/bash
# Template: mine a single workspace into mempalace.
# Copy to ~/.mempalace/mine-<your-wing>.sh and edit the marked sections.
# install.sh will not symlink this file — your live mine-*.sh scripts live in ~/.mempalace/.

set -e

[ -f "$HOME/.claude-setup/config.sh" ] && source "$HOME/.claude-setup/config.sh"

# --- Edit: which workspace repo to mine and which wing it lands in ---
WORKSPACE_ROOT="${WORKSPACE_A_REPO:-$HOME/REPOS/workspace-a}"
WING_NAME="workspace-a"

# --- Edit: which subtrees to copy. Use rsync with appropriate excludes. ---
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

RSYNC_EXCLUDES=(--exclude='node_modules' --exclude='dist' --exclude='build' --exclude='coverage')

# Example: copy specific app/lib subtrees. Add or remove rsync calls as needed.
# rsync -a "${RSYNC_EXCLUDES[@]}" "$WORKSPACE_ROOT/apps/<your-app>/" "$TEMP_DIR/apps/<your-app>/"
# rsync -a "${RSYNC_EXCLUDES[@]}" "$WORKSPACE_ROOT/libs/<your-lib>/" "$TEMP_DIR/libs/<your-lib>/"

# Optional: include top-level docs/config so the palace can answer about them
cp "$WORKSPACE_ROOT/CLAUDE.md" "$TEMP_DIR/CLAUDE.md" 2>/dev/null || true
cp "$WORKSPACE_ROOT/README.md" "$TEMP_DIR/README.md" 2>/dev/null || true

echo "Mining $WING_NAME from temp dir: $TEMP_DIR"
FILE_COUNT=$(find "$TEMP_DIR" -type f | wc -l | tr -d ' ')
echo "Files to process: ~$FILE_COUNT"
echo ""

python3 -m mempalace mine "$TEMP_DIR" --wing "$WING_NAME"
