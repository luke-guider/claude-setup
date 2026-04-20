#!/bin/bash
# Pre-commit quality checks — runs gitleaks, eslint, prettier, coderabbit on staged files
# Called by Claude Code PreToolUse hook when git commit is detected

set -euo pipefail

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.(ts|tsx|js|jsx)$' || true)

if [ -z "$STAGED_FILES" ]; then
  exit 0
fi

ERRORS=0
REVIEW_FILE="/tmp/.coderabbit-review-$$"

# 1. Gitleaks secret scan on staged files
echo "Running gitleaks on staged files..."
if command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks git --staged --no-banner 2>&1; then
    echo "FAILED: Gitleaks found secrets in staged files"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "WARNING: gitleaks not found — skipping secret scan"
fi

# 2. ESLint on staged files
echo "Running eslint on staged files..."
if ! echo "$STAGED_FILES" | xargs eslint --no-error-on-unmatched-pattern 2>&1 | tail -30; then
  echo "FAILED: ESLint found errors in staged files"
  ERRORS=$((ERRORS + 1))
fi

# 3. Prettier check on staged files
echo "Running prettier --check on staged files..."
if ! echo "$STAGED_FILES" | xargs prettier --check 2>&1 | tail -20; then
  echo "FAILED: Prettier formatting issues in staged files"
  ERRORS=$((ERRORS + 1))
fi

# 4. CodeRabbit review on uncommitted changes
# Skip if user has acknowledged the review (CODERABBIT_REVIEWED=1)
if [ "${CODERABBIT_REVIEWED:-}" = "1" ]; then
  echo "CodeRabbit review: skipped (previously reviewed and acknowledged)"
elif command -v coderabbit >/dev/null 2>&1; then
  echo "Running coderabbit review (uncommitted)..."
  REVIEW_OUTPUT=$(coderabbit review --type uncommitted --plain --no-color 2>&1 || true)
  echo "$REVIEW_OUTPUT" | tail -50

  if echo "$REVIEW_OUTPUT" | grep -qE '^Type: '; then
    echo ""
    echo "BLOCKED: CodeRabbit has review comments. Fix the issues or acknowledge with CODERABBIT_REVIEWED=1"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "WARNING: coderabbit CLI not found — skipping review"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "BLOCKED: $ERRORS check(s) failed. Fix issues before committing."
  exit 2
fi

echo ""
echo "All pre-commit checks passed."
