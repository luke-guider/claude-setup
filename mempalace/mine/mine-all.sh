#!/bin/bash
set -e

[ -f "$HOME/.claude-setup/config.sh" ] && source "$HOME/.claude-setup/config.sh"
THRIVE_ROOT="${THRIVE_REPO:-$HOME/REPOS/Thrive}"

echo "=== Mining all wings sequentially ==="
echo ""

echo "=== Step 1/3: Frontend (thrive-frontend) ==="
"$HOME/.mempalace/mine-frontend.sh"
echo ""

echo "=== Step 2/3: Guider ==="
"$HOME/.mempalace/mine-guider.sh"
echo ""

echo "=== Step 3/3: Thrive backend ==="
python3 -m mempalace mine "$THRIVE_ROOT"
echo ""

echo "=== All mines complete. Checking status ==="
python3 -m mempalace status
