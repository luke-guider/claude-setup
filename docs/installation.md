# Installation

## Prerequisites

- macOS or Linux
- git
- rsync
- python3
- `claude` CLI (https://claude.ai/code)
- `mempalace` Python package: `pip3 install mempalace`

## Fresh Install

```bash
git clone <repo-url> ~/claude-setup
cd ~/claude-setup
./install.sh
```

The installer:
1. Checks prerequisites
2. Detects or prompts for paths (THRIVE_REPO, GUIDER_REPO, BACKUP_SHARE)
3. Writes `~/.claude-setup/config.sh`
4. Backs up any existing files in `~/.claude/` or `~/.mempalace/` to `~/.claude/backup-pre-install/<timestamp>/`
5. Creates symlinks from target locations to repo files
6. Patches `mempalace/config.json` palace_path to match `$HOME`
7. Optionally offers:
   - SessionEnd auto-backup hook (manual merge into `settings.json`)
   - Weekly scheduled backup via launchd
   - Palace restore from existing `$BACKUP_SHARE/claude-backup/`

## Update Existing Install

From the claude-setup repo:

```bash
git pull
./install.sh --update
```

`--update` mode skips prompts. Uses existing `~/.claude-setup/config.sh`.

## Uninstall

```bash
# Remove symlinks (doesn't touch repo or backups)
find ~/.claude ~/.mempalace -type l -lname '*claude-setup*' -delete

# Remove config
rm -rf ~/.claude-setup

# Optionally restore pre-install backup
ls ~/.claude/backup-pre-install/
# Pick a timestamp and copy files back:
cp -r ~/.claude/backup-pre-install/<timestamp>/.claude/* ~/.claude/
```

## Troubleshooting

**"BACKUP_SHARE not mounted"**: The installer wrote a path (e.g., `/Volumes/NAS`) that isn't currently available. Either mount the share or edit `~/.claude-setup/config.sh` with a reachable path.

**"mempalace Python package not installed"**: `pip3 install mempalace`

**"claude CLI not found"**: Install from https://claude.ai/code

**Symlinks broken after moving the repo**: Re-run `./install.sh --update` from the new repo location.
