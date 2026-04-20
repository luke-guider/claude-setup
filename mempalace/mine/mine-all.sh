#!/bin/bash
set -e

echo "=== Mining all wings sequentially ==="
echo ""

echo "=== Step 1/3: Frontend (thrive-frontend) ==="
/Users/lukebeach/.mempalace/mine-frontend.sh
echo ""

echo "=== Step 2/3: Guider ==="
/Users/lukebeach/.mempalace/mine-guider.sh
echo ""

echo "=== Step 3/3: Thrive backend ==="
python3 -m mempalace mine /Users/lukebeach/REPOS/Thrive
echo ""

echo "=== All mines complete. Checking status ==="
python3 -m mempalace status
