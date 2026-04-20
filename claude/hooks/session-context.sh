#!/bin/bash
set -euo pipefail

# Source per-machine config if present
[ -f "$HOME/.claude-setup/config.sh" ] && source "$HOME/.claude-setup/config.sh"

CWD="$(pwd)"
CONTEXT_DIR="$HOME/.claude/context"
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

detect_workspace() {
  if echo "$CWD" | grep -qi 'guider'; then
    echo "guider"
  elif echo "$CWD" | grep -qiE 'thrive|Thrive'; then
    echo "thrive"
  else
    echo "unknown"
  fi
}

detect_service_thrive() {
  local service=""
  local known_services="content-core mentorship-core graphql-service user-service user-service-core api-service goals-service ai-router-core embedding-service content-event-service tag-service tenant-service prompt-service thrive-sdk secure-request-handler"

  for svc in $known_services; do
    if echo "$CWD" | grep -qi "$svc"; then
      service="$svc"
      break
    fi
  done

  if [ -z "$service" ] && echo "$CWD" | grep -qi "frontend"; then
    service="frontend"
  fi

  if [ -z "$service" ] && [ -n "$BRANCH" ]; then
    for svc in $known_services; do
      if echo "$BRANCH" | grep -qi "${svc}"; then
        service="$svc"
        break
      fi
    done
  fi

  echo "$service"
}

detect_service_guider() {
  local service=""
  local cwd_lower
  cwd_lower=$(echo "$CWD" | tr '[:upper:]' '[:lower:]')

  if echo "$cwd_lower" | grep -q '/apps/api'; then service="api"
  elif echo "$cwd_lower" | grep -q '/apps/admin'; then service="admin"
  elif echo "$cwd_lower" | grep -q '/apps/front-end'; then service="front-end"
  elif echo "$cwd_lower" | grep -q '/apps/bot'; then service="bot"
  elif echo "$cwd_lower" | grep -q '/apps/sanity'; then service="sanity"
  elif echo "$cwd_lower" | grep -q '/functions/'; then service="functions"
  elif echo "$cwd_lower" | grep -q '/packages/'; then
    service=$(echo "$cwd_lower" | sed -n 's|.*/packages/\([^/]*\).*|\1|p')
  fi

  echo "$service"
}

service_to_domain_thrive() {
  local svc="$1"
  case "$svc" in
    content-core|content-event-service|content-listing-service) echo "content" ;;
    mentorship-core) echo "mentoring" ;;
    user-service|user-service-core|user-listing-service) echo "user" ;;
    graphql-service|api-service) echo "gateway" ;;
    ai-router-core|embedding-service) echo "ai" ;;
    tenant-service) echo "tenant" ;;
    prompt-service) echo "communication" ;;
    goals-service|tag-service) echo "goals" ;;
    frontend) echo "frontend" ;;
    thrive-sdk|secure-request-handler) echo "shared-libs" ;;
    *) echo "general" ;;
  esac
}

resolve_deps_thrive() {
  local svc="$1"
  local graph="${THRIVE_REPO:-$HOME/REPOS/Thrive}/docs/service-graph.toml"
  [ ! -f "$graph" ] && return

  local safe
  safe=$(echo "$svc" | tr '-' '_')
  local in_section=0
  local deps=""

  while IFS= read -r line; do
    if echo "$line" | grep -q "^\[services\.${safe}\]"; then
      in_section=1
      continue
    fi
    if [ "$in_section" -eq 1 ]; then
      if echo "$line" | grep -q '^\['; then
        break
      fi
      if echo "$line" | grep -q '^depends_on'; then
        deps=$(echo "$line" | sed 's/depends_on = \[//; s/\]//; s/"//g; s/,/ /g')
      fi
    fi
  done < "$graph"

  echo "$deps"
}

WORKSPACE=$(detect_workspace)

if [ "$WORKSPACE" = "thrive" ]; then
  SERVICE=$(detect_service_thrive)
  if [ -n "$SERVICE" ]; then
    DOMAIN=$(service_to_domain_thrive "$SERVICE")
    DEPS=$(resolve_deps_thrive "$SERVICE")

    echo "# Working Context: $SERVICE"
    echo "Domain: $DOMAIN | Mempalace: thrive/$DOMAIN"
    echo ""

    if [ -n "$DEPS" ]; then
      echo "## Connected Services"
      for dep in $DEPS; do
        dep_domain=$(service_to_domain_thrive "$dep")
        echo "- $dep ($dep_domain)"
      done
      echo ""
    fi

    echo "## Applicable Rules"
    if [ -f "$CONTEXT_DIR/thrive/domains/$DOMAIN.md" ]; then
      echo "- $CONTEXT_DIR/thrive/domains/$DOMAIN.md"
    fi
    if [ "$DOMAIN" = "frontend" ]; then
      echo "- $CONTEXT_DIR/thrive/concerns/graphql-codegen.md"
      echo "- $CONTEXT_DIR/thrive/concerns/testing-patterns.md"
    else
      echo "- $CONTEXT_DIR/thrive/concerns/mongodb-tenancy.md"
      echo "- $CONTEXT_DIR/thrive/concerns/sqs-patterns.md"
      echo "- $CONTEXT_DIR/thrive/concerns/error-handling.md"
      echo "- $CONTEXT_DIR/thrive/concerns/auth-middleware.md"
      echo "- $CONTEXT_DIR/thrive/concerns/testing-patterns.md"
      if [ "$DOMAIN" = "gateway" ] || [ "$DOMAIN" = "mentoring" ] || [ "$DOMAIN" = "goals" ]; then
        echo "- $CONTEXT_DIR/thrive/concerns/graphql-codegen.md"
      fi
    fi
    echo ""

    echo "## Related: Guider Platform"
    if [ "$DOMAIN" = "mentoring" ]; then
      echo "Mentoring migrating from guider. Reference: mempalace_search(\"matching\", wing: \"guider\")"
    else
      echo "Legacy mentoring platform at ${GUIDER_REPO:-$HOME/REPOS/guider/platform}"
    fi
  else
    echo "# Working Context: Thrive (workspace root)"
    echo "No specific service detected. Use \`docs/service-graph.toml\` for service lookup."
    echo ""
    echo "## Domains"
    echo "ai, content, gateway, mentoring, user, tenant, communication, goals, frontend, infra"
    echo ""
    echo "## Fragments"
    echo "- $CONTEXT_DIR/thrive/domains/"
    echo "- $CONTEXT_DIR/thrive/concerns/"
  fi

elif [ "$WORKSPACE" = "guider" ]; then
  SERVICE=$(detect_service_guider)
  if [ -n "$SERVICE" ]; then
    echo "# Working Context: guider/$SERVICE"
    echo "Mempalace: guider/apps"
    echo ""
    echo "## Applicable Rules"
    echo "- $CONTEXT_DIR/guider/concerns/rush-workflows.md"
    if [ -f "$CONTEXT_DIR/guider/domains/$SERVICE.md" ]; then
      echo "- $CONTEXT_DIR/guider/domains/$SERVICE.md"
    fi
    if [ "$SERVICE" = "api" ] || [ "$SERVICE" = "bot" ]; then
      echo "- $CONTEXT_DIR/guider/concerns/shared-packages.md"
    fi
    if [ "$SERVICE" = "functions" ]; then
      echo "- $CONTEXT_DIR/guider/concerns/azure-functions.md"
    fi
    echo ""
    echo "## Related: Thrive Platform"
    echo "Mentoring migration target. Reference: mempalace_search(\"mentoring\", wing: \"thrive\")"
  else
    echo "# Working Context: Guider (workspace root)"
    echo "Rush monorepo. 59 projects across apps/, packages/, functions/."
    echo ""
    echo "## Fragments"
    echo "- $CONTEXT_DIR/guider/domains/"
    echo "- $CONTEXT_DIR/guider/concerns/"
  fi
else
  echo "# Working Context: Unknown workspace"
  echo "CWD: $CWD"
fi
