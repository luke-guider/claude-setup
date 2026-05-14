# Claude Setup

Personal backup of Claude Code + mempalace configuration. Install on a fresh machine to restore hooks, context fragments, custom skills, and mempalace config.

## Quick Start

```bash
git clone <repo-url> ~/claude-setup
cd ~/claude-setup
./install.sh
```

## What's Included

- Global `~/.claude/CLAUDE.md` rules
- `session-context.sh` hook (Layer 0 progressive disclosure)
- Pre-commit and pre-push quality gates
- Context fragments for your workspace domains *(private, not in this repo)*
- Custom skills (backup-palace, eod-summary, review, review-coderabbit)
- Mempalace config, identity, wing map
- Mempalace mining scripts and auto-save hooks
- Palace backup scripts (rsync + tarball snapshots)

## What's NOT Included

- Mempalace palace data (~2GB) — backed up separately to your local share
- Plugin installations (restored by Claude Code from settings.json)
- Runtime state (sessions, cache, tasks)

## Drop-In Reference for AI Prompts

For a one-pager describing this whole setup (plugins, MCPs, skills, CCO, hooks, conventions), pass this raw URL to any AI tool:

```
https://raw.githubusercontent.com/luke-guider/claude-setup/main/docs/setup-reference.md
```

## See Also

- `docs/installation.md` — detailed install steps
- `docs/architecture.md` — how the three-layer context system works
- `docs/memory-flow.md` — how context survives between sessions (mempalace + save hooks + fragments)
- `docs/backup-restore.md` — palace backup/restore flows
- `docs/setup-reference.md` — public overview of the full setup (plugins, MCPs, skills, CCO)
- `docs/adding-fragments.md` — extending the fragment library
