#!/bin/bash
# Pre-push quality checks — runs tsc and coderabbit on committed changes
# Called by Claude Code PreToolUse hook when git push is detected

set -euo pipefail

# 1. Gitleaks secret scan on committed changes
echo "Running gitleaks on committed changes..."
if command -v gitleaks >/dev/null 2>&1; then
  BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null || git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
  if [ -n "$BASE" ]; then
    if ! gitleaks git --no-banner --log-opts="$BASE..HEAD" 2>&1; then
      echo "BLOCKED: Gitleaks found secrets in committed changes"
      exit 2
    fi
  else
    echo "WARNING: Could not determine base commit — skipping gitleaks"
  fi
else
  echo "WARNING: gitleaks not found — skipping secret scan"
fi

# 2. TypeScript type check (warning only — repo configs may be custom)
if [ -f "tsconfig.json" ]; then
  echo "Running tsc --noEmit..."
  if ! tsc --noEmit 2>&1 | tail -20; then
    echo "WARNING: TypeScript type errors found — review before pushing"
  fi
fi

# 3. CodeRabbit review on committed changes
# Skip if user has acknowledged the review (CODERABBIT_REVIEWED=1)
if [ "${CODERABBIT_REVIEWED:-}" = "1" ]; then
  echo "CodeRabbit review: skipped (previously reviewed and acknowledged)"
elif command -v coderabbit >/dev/null 2>&1; then
  echo "Running coderabbit review (committed)..."
  REVIEW_OUTPUT=$(coderabbit review --type committed --plain --no-color 2>&1 || true)
  echo "$REVIEW_OUTPUT" | tail -50

  if echo "$REVIEW_OUTPUT" | grep -qE '^Type: '; then
    echo ""
    echo "BLOCKED: CodeRabbit has review comments. Fix the issues or acknowledge with CODERABBIT_REVIEWED=1"
    exit 2
  fi
else
  echo "WARNING: coderabbit CLI not found — skipping review"
fi

echo ""
echo "Pre-push checks complete."
