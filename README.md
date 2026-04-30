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
- 24 context fragments for Thrive + Guider domains
- Custom skills (eod-summary, review, thrive-code, deploy-azure-function, backup-palace)
- Mempalace config, identity, wing map
- Mempalace mining scripts and auto-save hooks
- Palace backup scripts (rsync + tarball snapshots)

## What's NOT Included

- Mempalace palace data (~2GB) — backed up separately to your local share
- Plugin installations (restored by Claude Code from settings.json)
- Runtime state (sessions, cache, tasks)

## Alternative Install via Claude

Open Claude Code in this repo directory and say "install this setup". Claude reads `CLAUDE.md` and performs the install interactively.

## See Also

- `docs/installation.md` — detailed install steps
- `docs/architecture.md` — how the three-layer context system works
- `docs/backup-restore.md` — palace backup/restore flows
- `docs/setup-reference.md` — public overview of the full setup (plugins, MCPs, skills, CCO)
- `docs/adding-fragments.md` — extending the fragment library
