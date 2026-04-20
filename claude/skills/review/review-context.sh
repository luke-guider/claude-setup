#!/usr/bin/env bash
set -euo pipefail

# Phase 0 + Phase 1: Gather all review context and run automated tools
# Usage: review-context.sh [base-branch]
# Outputs structured JSON to stdout

# --- Phase 0: Context Detection ---

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo '{"error":"Not a git repository"}'; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

BRANCH=$(git branch --show-current)

# Base branch: use argument, or auto-detect
if [ -n "${1:-}" ]; then
  BASE="$1"
else
  BASE=""
  for b in main master develop; do
    if git rev-parse --verify "origin/$b" >/dev/null 2>&1; then
      BASE="origin/$b"
      break
    elif git rev-parse --verify "$b" >/dev/null 2>&1; then
      BASE="$b"
      break
    fi
  done
fi

if [ -z "$BASE" ]; then
  echo '{"error":"No base branch found. Checked: origin/main, origin/master, origin/develop"}'
  exit 1
fi

# Platform detection
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
PLATFORM="terminal"
if echo "$REMOTE_URL" | grep -q "github.com"; then
  PLATFORM="github"
elif echo "$REMOTE_URL" | grep -q "bitbucket.org"; then
  PLATFORM="bitbucket"
fi

# Changed files
CHANGED_FILES=$(git diff "$BASE"...HEAD --name-only 2>/dev/null || true)
if [ -z "$CHANGED_FILES" ]; then
  echo "{\"error\":\"No changes between $BRANCH and $BASE\"}"
  exit 1
fi

CHANGED_SOURCE=$(echo "$CHANGED_FILES" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs)$' || true)

# PR detection
PR_INFO="null"
if [ "$PLATFORM" = "github" ]; then
  PR_INFO=$(gh pr view --json number,url,headRefName 2>/dev/null || echo "null")
elif [ "$PLATFORM" = "bitbucket" ]; then
  if [ -n "${BITBUCKET_USERNAME:-}" ] && [ -n "${BITBUCKET_TOKEN:-}" ]; then
    WORKSPACE=$(echo "$REMOTE_URL" | sed -E 's|.*bitbucket.org[:/]([^/]+)/.*|\1|')
    REPO_SLUG=$(echo "$REMOTE_URL" | sed -E 's|.*bitbucket.org[:/][^/]+/([^.]+).*|\1|')
    BB_RESPONSE=$(curl -s -u "$BITBUCKET_USERNAME:$BITBUCKET_TOKEN" \
      "https://api.bitbucket.org/2.0/repositories/$WORKSPACE/$REPO_SLUG/pullrequests?q=source.branch.name=%22$BRANCH%22&state=OPEN" 2>/dev/null || echo '{"values":[]}')
    PR_INFO=$(echo "$BB_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    prs = data.get('values', [])
    if prs:
        pr = prs[0]
        print(json.dumps({'id': pr['id'], 'title': pr.get('title',''), 'workspace': '$WORKSPACE', 'repo_slug': '$REPO_SLUG'}))
    else:
        print('null')
except:
    print('null')
" 2>/dev/null || echo "null")
  else
    PR_INFO="null"
  fi
fi

# Project CLAUDE.md
CLAUDE_MD=""
[ -f "$REPO_ROOT/CLAUDE.md" ] && CLAUDE_MD=$(cat "$REPO_ROOT/CLAUDE.md")
[ -f "$REPO_ROOT/.claude/CLAUDE.md" ] && CLAUDE_MD="$CLAUDE_MD$(cat "$REPO_ROOT/.claude/CLAUDE.md")"

# Diff
DIFF=$(git diff "$BASE"...HEAD 2>/dev/null || true)

# --- Phase 1: Automated Tools ---

# 1a. Gitleaks
GITLEAKS_RESULT="SKIPPED: not installed"
if command -v gitleaks >/dev/null 2>&1; then
  GITLEAKS_RESULT=$(gitleaks git --log-opts="$BASE...HEAD" --report-format json 2>&1 || echo "SKIPPED: scan failed")
fi

# 1b. ESLint
ESLINT_RESULT="SKIPPED: no source files"
if [ -n "$CHANGED_SOURCE" ]; then
  if ls .eslintrc* eslint.config.* >/dev/null 2>&1; then
    ESLINT_RESULT=$(npx eslint --format json $CHANGED_SOURCE 2>&1 || true)
  else
    ESLINT_RESULT="SKIPPED: no config"
  fi
fi

# 1c. Prettier
PRETTIER_RESULT="SKIPPED: no source files"
if [ -n "$CHANGED_SOURCE" ]; then
  if ls .prettierrc* prettier.config.* >/dev/null 2>&1; then
    PRETTIER_RESULT=$(npx prettier --check $CHANGED_SOURCE 2>&1 || true)
  else
    PRETTIER_RESULT="SKIPPED: no config"
  fi
fi

# 1d. CodeRabbit
CODERABBIT_RESULT="SKIPPED: not installed"
if command -v coderabbit >/dev/null 2>&1; then
  CODERABBIT_RESULT=$(coderabbit review --agent --base "$BASE" 2>&1 || \
    coderabbit review --plain --base "$BASE" 2>&1 || \
    echo "SKIPPED: review failed (try: coderabbit auth login)")
fi

# --- Output ---

python3 -c "
import json, sys

print(json.dumps({
    'context': {
        'branch': '$BRANCH',
        'base': '$BASE',
        'platform': '$PLATFORM',
        'remote_url': '$REMOTE_URL',
        'repo_root': '$REPO_ROOT',
        'pr': $PR_INFO,
        'changed_files': $(echo "$CHANGED_FILES" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo '[]'),
        'changed_source': $(echo "$CHANGED_SOURCE" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo '[]'),
    },
    'tools': {
        'gitleaks': $(python3 -c "import json; print(json.dumps('$GITLEAKS_RESULT'.replace(\"'\", \"\")))" 2>/dev/null || echo '"unknown"'),
        'eslint': 'see_raw',
        'prettier': 'see_raw',
        'coderabbit': 'see_raw',
    }
}, indent=2))
" 2>/dev/null

# Raw tool outputs (too large / complex for JSON embedding)
echo ""
echo "---ESLINT_RAW---"
echo "$ESLINT_RESULT"
echo "---PRETTIER_RAW---"
echo "$PRETTIER_RESULT"
echo "---CODERABBIT_RAW---"
echo "$CODERABBIT_RESULT"
echo "---DIFF_RAW---"
echo "$DIFF"
echo "---CLAUDE_MD_RAW---"
echo "$CLAUDE_MD"
