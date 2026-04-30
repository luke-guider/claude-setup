# Claude Code Setup Reference

A practical overview of the Claude Code configuration used across Guider/Thrive projects. Designed to be: (a) a teammate's quick-reference, and (b) ingestible by an agent tool as a pattern for building a similar setup elsewhere.

---

## Overview

This is a **progressive disclosure** setup:

- **Hooks** load minimal context at session start (workspace, service, branch) — ~500 bytes
- **Domain fragments** (not in this public repo) are pulled on-demand when the task touches a specific domain — ~3-6 KB per domain
- **Skills** encapsulate repeatable workflows in structured SKILL.md files
- **CCO** (Claude Code Orchestrator) routes work between free/cheap models and PRO based on task complexity
- **Mempalace** provides persistent agent memory (semantic search, knowledge graph, timeline) across sessions

The repo is public. Context fragments containing Guider/Thrive business logic are excluded.

---

## Claude Code Plugins

Plugins are installed via the Claude Code plugin catalog. Enable/disable in `settings.json`. Below: which ones are active, and whether they're custom (self-authored) or downloaded (from the plugin catalog).

| Plugin | Source | Purpose |
|---|---|---|
| **coderabbit** | Downloaded | AI code review (standalone or integrated) |
| **frontend-design** | Downloaded | Figma-to-code design system integration |
| **github** | Downloaded | GitHub CLI integration, PR creation |
| **feature-dev** | Downloaded | Structured feature development (plan → implement → review) |
| **code-simplifier** | Downloaded | Refactors code for clarity without changing behavior |
| **superpowers** | Downloaded | Process skills — brainstorming, TDD, debugging, systematic development |
| **typescript-lsp** | Downloaded | TypeScript language server for code intelligence |
| **commit-commands** | Downloaded | `commit`, `push`, `clean-gone` branch helpers |
| **security-guidance** | Downloaded | Security review prompts and best practices |
| **pr-review-toolkit** | Downloaded | PR reviewer agent, code simplifier, comment analysis |
| **figma** | Downloaded | Read designs from Figma, capture web pages to Figma |
| **claude-md-management** | Downloaded | Audit and maintain CLAUDE.md across projects |
| **skill-creator** | Downloaded | Create new custom skills from templates |
| **atlassian** | Downloaded | Jira/Confluence integration (search, create, update) |
| **slack** | Downloaded | Send messages, read threads, channel summaries |
| **microsoft-docs** | Downloaded | Microsoft Learn/Azure documentation search |
| **playground** | Downloaded | Interactive HTML/CSS/JS snippets |
| **huggingface-skills** | Downloaded | Hugging Face Hub CLI, model training, datasets |
| **deploy-on-aws** | Downloaded | AWS CDK, CloudFormation, cost analysis |
| **aws-serverless** | Downloaded | SAM, Lambda, API Gateway, streaming (Kafka/Kinesis/SQS) |
| **sanity-plugin** | Downloaded | Sanity CMS integration (notion-type database CMS) |

> **Pattern:** Every active plugin follows a standard naming convention (`<name>@claude-plugins-official`). Enable by setting `"enabledPlugins": { "<name>@claude-plugins-official": true }` in `settings.json`.

---

## MCP Servers

MCP (Model Context Protocol) servers provide tool access to external services. Some require OAuth; some are built-in. Authentication state lives in `mcp-needs-auth-cache.json`, not config files.

| MCP Server | Type | Auth |
|---|---|---|
| **Figma** | Downloaded | OAuth (per-session) |
| **Google Calendar** | Downloaded | OAuth |
| **HubSpot** | Downloaded | OAuth |
| **incident.io** | Downloaded | OAuth |
| **Notion** | Downloaded | OAuth |
| **Smartsheet** | Downloaded | OAuth |
| **Webflow** | Downloaded | OAuth |
| **Slack** | Plugin-bundled | OAuth |
| **Atlassian (Jira/Confluence)** | Plugin-bundled | OAuth |
| **Microsoft Learn** | Plugin-bundled | None (public docs) |
| **MemPalace** | Personal MCP | Local file access |
| **AWS Serverless** | Plugin-bundled | AWS credentials via local profile/SSO |
| **Deploy on AWS** | Plugin-bundled | AWS credentials via local profile/SSO |
| **AWS Pricing** | Plugin-bundled | AWS credentials via local profile/SSO |
| **Thrive (Prod/Staging/Sandbox/Tribe/Cheddar)** | Personal MCP | OAuth via Thrive |
| **Trumpet** | Downloaded | OAuth |

> **Pattern:** Personal MCPs (MemPalace, Thrive clients) are installed from local sources and are not in the public plugin catalog. Built-in plugin MCPs (AWS, Slack, Atlassian) are bundled with their parent plugin.

---

## CCO — Claude Code Orchestrator

CCO is a **shell script + skill wrapper** layered on `claude-code-router`. It routes work between free/cheap models and PRO based on task complexity.

**Why it exists:** Most Claude Code tasks (lint fixes, mechanical refactoring) do not need PRO-tier models. Running them on free Ollama Cloud saves money. Tasks that genuinely need Sonnet/Opus get a clean handoff rather than dragging expensive context forward.

### Architecture

Three layers, each replaceable:

```
Claude Code session (brain)
  → cco dispatcher (shell)
  → claude-code-router (transport)
  → Ollama / Anthropic (models)
  + mempalace (state, cross-session memory)
```

### Modes

| Mode | Driver Model | Sub-agents | Use Case |
|---|---|---|---|
| `cco` (default) | Free Ollama Cloud (Kimi K2.5) | Cheap via ccr | Daily volume — cost $0 |
| `cco --pro-driver` | PRO Sonnet/Opus | Anthropic PRO | Hard architecture, deep debugging |

### Skills

| CCO Skill | Trigger | What It Does |
|---|---|---|
| **refine** | `/refine`, `cco refine`, or driver detects vague prompt | One-shot prompt interview to clarify goals before work starts |
| **handoff-to-pro** | Driver decides task needs PRO (default mode) | Generates compact handoff bundle (clipboard + file) — paste into fresh `claude` session |
| **delegate-to-cheap** | Driver decides sub-task is mechanical (pro-driver mode) | Auto shell-out to cheap model via `claude-code-router` |
| **checkpoint** | Before any cross-model dispatch | Writes mempalace drawer tagged `cco:checkpoint` with 2-3 KB seed context |
| **recommend-defaults** | `cco bootstrap`, `cco recommend-models` | Fetches live model rankings from Ollama registry + HuggingFace; writes ccr config |

### Commands

```bash
cco                       # default: cheap drives, escalate via handoff
cco --pro-driver          # PRO drives, delegate mechanical work to cheap
cco refine "<prompt>"     # one-shot prompt interview
cco recommend-models      # re-run model recommender
cco doctor                # smoke-test install
```

### Daily Workflow

1. Start work with `cco`
2. If task is mechanical, the default driver handles it
3. If task needs PRO, driver fires `handoff-to-pro`, generates handoff bundle
4. Create fresh `claude` session, handoff bundle seeded into mempalace
5. Result flows back or the PRO session continues independently

> **Install:** `curl -fsSL https://<path>/install.sh | bash; cco bootstrap` — this repo is private. For this pattern, the install script installs `claude-code-router`, verifies prereqs, and runs the recommender.

---

## Custom Skills (Self-Authored)

Live in `claude/skills/` as `SKILL.md` files. Triggered by slash commands, keywords, or programmatic invocation.

All self-authored. Source: this repo at `claude/skills/`. Installation via symlink by `install.sh`.

| Skill | Trigger | Use |
|---|---|---|
| **backup-palace** | "backup", "eod" | Rsync mempalace to local backup share. Reads `BACKUP_SHARE` from `config.sh`. |
| **deploy-azure-function** | CI deploy fails with unpublished `@guider-global/*` | Uses Verdaccio to publish locally, then deploys Azure Function manually. |
| **eod-summary** | "end of day", "eod" | Scans recent sessions, produces markdown handoff to clipboard. |
| **review** | "review code", "review this branch" | Runs gitleaks, ESLint, Prettier, CodeRabbit, parallel agents; posts inline PR comments. |
| **thrive-code** | "run quality checks", "check my code" | Prettier + ESLint + Jest + Cypress; reads domain fragments first. |

### Skill Pattern

Every custom skill follows this structure:

```
claude/skills/<name>/
  SKILL.md              # trigger, description, procedure
  review-context.sh     # optional: shell helper (review skill uses this)
```

The `SKILL.md` is parsed by the Claude Code skill system. It contains:
- `name` and `description` (used by auto-discovery)
- `# <title>` header
- `## When to Use` — keywords/gates for invocation
- `## Procedure` — ordered steps, often referencing shell scripts or other tools

> **Pattern:** If a workflow repeats more than twice, extract it as a `SKILL.md`. Place in `claude/skills/<name>/SKILL.md`. Claude loads it automatically.

---

## Hooks

Hooks fire automatically at Claude Code lifecycle events. Configured in `settings.json`.

| Hook | Command | Source |
|---|---|---|
| **SessionStart** | `session-context.sh` | Custom — resolves workspace, service, branch, and applicable domain fragments |
| **PreToolUse (git commit)** | `pre-commit-checks.sh` | Custom — runs gitleaks, validates commit message format |
| **PreToolUse (git push)** | `pre-push-checks.sh` | Custom — runs tests, blocks push if checks fail |

> **Pattern:** SessionStart hooks live at `<repo>/claude/hooks/`. They are symlinked to `~/.claude/hooks/` via `install.sh`. The hook is a bash script with a 5000ms timeout — must be fast or it silently fails.

---

## Daily Workflow

```
1. Open terminal at project root
   → SessionStart hook auto-loads workspace context

2. Describe task in natural language
   → Claude pulls domain fragments on demand

3. Work proceeds; sub-tasks dispatched via CCO if needed
   → checkpoint skill persists state to mempalace

4. End of day
   → /eod-summary or "eod" → clipboard handoff for tomorrow
   → backup-palace → mempalace snapshot to backup share

5. Pre-commit quality gates (automatic)
   → gitleaks → ESLint → commit message check
   → Push gates — test run, block if red
```

---

## Configuration Files

| File | Purpose | In Repo? |
|---|---|---|
| `claude/settings.json` | Plugin enable/disable, hooks, env | Committed |
| `mempalace/config.json` | Wing map, identity, backup target | Excluded (machine-local paths) |
| `mempalace/wing_config.json` | Room-to-repo mapping for palace | Excluded (generated by CLI) |
| `config/paths.sh` | Per-machine paths (`BACKUP_SHARE`, etc.) | Excluded (generated) |
| `config/paths.example.sh` | Template for `paths.sh` | **Committed** (reference) |

---

## For an Agent Replicating This Pattern

If you want to build something similar, here is the ordered checklist an agent could follow:

1. **Base setup**
   - Install Claude Code CLI (`npm install -g @anthropic-ai/claude`)
   - Create `~/.claude/` directory for config, hooks, skills
   - Install `claude-code-router` if using CCO-style model routing
   - Install `ollama` if using free local/cheap endpoints

2. **Plugins**
   - Install from Claude Code plugin catalog or `settings.json` copy
   - Mark which are custom-authored (not from catalog)

3. **MCP Servers**
   - Configure OAuth-based MCPs (Slack, Atlassian, Figma, Google, Notion)
   - Configure credential-based MCPs (AWS — uses local profile)
   - Configure personal MCPs (MemPalace, etc. — local file-based)

4. **Hooks**
   - Create `session-context.sh` → fast (<5s), reads CWD/branch, outputs Working Context block
   - Create `pre-commit-checks.sh` → gitleaks + commit format validation
   - Create `pre-push-checks.sh` → test gate
   - Symlink to `~/.claude/hooks/` and register in `settings.json`

5. **CCO (optional)**
   - Write install script that installs `claude-code-router`
   - Write dispatcher script (`cco`) with two modes: default (cheap drives) and pro-driver
   - Write 5 skills: `refine`, `handoff-to-pro`, `delegate-to-cheap`, `checkpoint`, `recommend-defaults`
   - Install models via `recommend-defaults` (live data, not static list)

6. **Custom Skills**
   - For each repeating workflow, create `claude/skills/<name>/SKILL.md`
   - Follow structure: Name → Description → When to Use → Procedure → Steps

7. **Memory (optional)**
   - Set up MemPalace MCP or equivalent persistent semantic memory
   - Configure wings/rooms mapping repos to memory domains
   - Add auto-save hooks (post-session) and mining scripts (periodic knowledge extraction)

8. **Session context**
   - Write `CLAUDE.md` at repo root (global rules) and at project/domain roots (local rules)
   - Use progressive disclosure: Layer 0 (session start) → Layer 1 (on-demand fragments)

---

## Privacy & Security Notes

- This repo is public. No secrets, tokens, or API keys are committed.
- `claude/context/` (domain fragments with business logic) is excluded via `.gitignore`.
- `config/paths.sh` (local paths) is excluded via `.gitignore`.
- `mempalace/palace/` and `knowledge_graph.sqlite3` are excluded (runtime data, large).
- Always review a repo before making it public. Scrub for service names, provider configs, internal URLs.

---

## What's Not In This Reference

- Full CCO install script — the CCO repo is private
- Context fragments — business logic, not public
- `mempalace/palace/` data — ~2 GB, backed up separately
- Plugin installation instructions — installed via Claude Code UI or `settings.json` restoration

For teammates who need the full private context: clone `claude-setup`, run `install.sh`, and work from there.

For external readers: the **pattern** above is the complete gist.
