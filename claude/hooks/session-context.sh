#!/bin/bash
set -euo pipefail

# Source per-machine config if present
[ -f "$HOME/.claude-setup/config.sh" ] && source "$HOME/.claude-setup/config.sh"

CWD="$(pwd)"
CONTEXT_DIR="$HOME/.claude/context"
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Detect workspace from context directory names matching CWD path
detect_workspace() {
  local cwd_lower; cwd_lower=$(echo "$CWD" | tr '[:upper:]' '[:lower:]')
  if [ -d "$CONTEXT_DIR" ]; then
    for ws_dir in "$CONTEXT_DIR"/*/; do
      [ -d "$ws_dir" ] || continue
      local ws_name; ws_name=$(basename "$ws_dir")
      if echo "$cwd_lower" | grep -qi "${ws_name}"; then
        echo "$ws_name"
        return 0
      fi
    done
  fi
  echo "unknown"
}

# Detect "service" from subdirectories in CWD (e.g., apps/, services/)
detect_service_from_path() {
  local service=""
  local cwd_lower; cwd_lower=$(echo "$CWD" | tr '[:upper:]' '[:lower:]')
  # Try common subdirectory patterns
  if echo "$cwd_lower" | grep -qE '/(apps|services|packages|functions)/'; then
    service=$(echo "$cwd_lower" | sed -nE 's|.*/(apps|services|packages|functions)/([-a-z0-9]+).*|\2|p' | head -1)
  fi
  # Fallback: branch name hints
  if [ -z "$service" ] && [ -n "$BRANCH" ]; then
    service=$(echo "$BRANCH" | sed -nE 's/.*[-/]?(service|feature)[-/]?([-a-z0-9]+).*/\2/p' | head -1)
  fi
  echo "$service"
}

WORKSPACE=$(detect_workspace)

if [ "$WORKSPACE" = "unknown" ]; then
  echo "# Working Context: Unknown workspace"
  echo "CWD: $CWD"
  echo ""
  if [ -d "$CONTEXT_DIR" ] && [ "$(ls -A "$CONTEXT_DIR" 2>/dev/null)" ]; then
    echo "## Available Workspaces"
    for ctx in "$CONTEXT_DIR"/*/; do
      [ -d "$ctx" ] && echo "- $(basename "$ctx")"
    done
    echo ""
    echo "Add a workspace directory under claude/context/ that matches your CWD."
  else
    echo "No context directory found. Run ./install.sh to populate templates."
  fi
  exit 0
fi

WS_DIR="$CONTEXT_DIR/$WORKSPACE"
SERVICE=$(detect_service_from_path)

if [ -d "$WS_DIR/domains" ] && [ "$(ls -A "$WS_DIR/domains" 2>/dev/null)" ]; then
  # Workspace has domain fragments — list applicable ones
  echo "# Working Context: $WORKSPACE"
  if [ -n "$SERVICE" ]; then
    echo "Detected service path: $SERVICE | Branch: ${BRANCH:-none}"
  else
    echo "No service path detected | Branch: ${BRANCH:-none}"
  fi
  echo ""
  echo "## Applicable Domain Fragments"
  for f in "$WS_DIR/domains"/*.md; do
    [ -f "$f" ] && echo "- $f"
  done
  echo ""
  if [ -d "$WS_DIR/concerns" ] && [ "$(ls -A "$WS_DIR/concerns" 2>/dev/null)" ]; then
    echo "## Applicable Concern Fragments"
    for f in "$WS_DIR/concerns"/*.md; do
      [ -f "$f" ] && echo "- $f"
    done
    echo ""
  fi
else
  # Only templates present — minimal output
  echo "# Working Context: $WORKSPACE (templates only)"
  echo ""
  echo "=== ACTION REQUIRED ==="
  echo "This workspace only has template files. Before Claude can use context,"
  echo "populate the following directory with your actual domain content:"
  echo ""
  echo "  $WS_DIR/"
  echo ""
  echo "See claude/context-templates/README.md for guidance."
fi