# Claude Setup — Installation via Claude Code

This repo is Luke's Claude Code + mempalace configuration. When the user clones this and says "install this setup", follow the steps below.

## Quick Install

If the user just wants the full install, execute:

```bash
./install.sh
```

Report results as it runs. If it prompts for paths, relay the prompts to the user.

## Selective Install

If the user wants only parts of the setup, use these recipes. Always create symlinks from repo files to target locations (never copy) so edits flow back to the repo.

### Just Context Fragments

```bash
mkdir -p ~/.claude/context
ln -sfn "$PWD/claude/context/thrive" ~/.claude/context/thrive
ln -sfn "$PWD/claude/context/guider" ~/.claude/context/guider
```

### Just Hooks

```bash
mkdir -p ~/.claude/hooks
for f in claude/hooks/*.sh; do
  ln -sf "$PWD/$f" "$HOME/.claude/hooks/$(basename "$f")"
done
```

Then tell the user they need to add the hook commands to `~/.claude/settings.json` — show them `templates/session-end-hook.json` as an example.

### Just Custom Skills

```bash
mkdir -p ~/.claude/skills
for dir in claude/skills/*/; do
  name=$(basename "$dir")
  ln -sfn "$PWD/$dir" "$HOME/.claude/skills/$name"
done
```

### Just Mempalace Config

```bash
mkdir -p ~/.mempalace/hooks
ln -sf "$PWD/mempalace/config.json" ~/.mempalace/config.json
ln -sf "$PWD/mempalace/wing_config.json" ~/.mempalace/wing_config.json
ln -sf "$PWD/mempalace/identity.txt" ~/.mempalace/identity.txt
ln -sf "$PWD/mempalace/hooks/mempal_save_hook.sh" ~/.mempalace/hooks/
ln -sf "$PWD/mempalace/hooks/mempal_precompact_hook.sh" ~/.mempalace/hooks/
```

Then patch `palace_path` in `mempalace/config.json` to match `$HOME/.mempalace/palace`:

```bash
python3 -c "
import json, os
p = '$PWD/mempalace/config.json'
cfg = json.load(open(p))
cfg['palace_path'] = os.path.expanduser('~/.mempalace/palace')
json.dump(cfg, open(p, 'w'), indent=2)
"
```

## Per-Machine Config

All scripts read `~/.claude-setup/config.sh`. Create it if doing a selective install without `install.sh`:

```bash
mkdir -p ~/.claude-setup
cp config/paths.example.sh ~/.claude-setup/config.sh
# Then edit ~/.claude-setup/config.sh with actual paths
```

## Backup Restore

If the user has a palace backup on their `BACKUP_SHARE`:

```bash
./mempalace/backup/restore-palace.sh
```

If they have a specific snapshot tarball:

```bash
./mempalace/backup/restore-palace.sh /path/to/snapshot.tar.gz
```

## Important Rules

- ALWAYS use symlinks, NEVER copy files
- If a target path exists and isn't already a symlink to this repo, BACK IT UP FIRST to `~/.claude/backup-pre-install/<timestamp>/`
- Make all `.sh` files executable after symlinking
- Patch `mempalace/config.json` palace_path to match `$HOME` on this machine
- Don't modify `~/.claude/settings.json` automatically — show the user the `templates/session-end-hook.json` snippet and let them merge it manually

## Verification

After install, confirm:

```bash
# Hooks work
ls -la ~/.claude/hooks/
bash -n ~/.claude/hooks/session-context.sh

# Context fragments present
ls ~/.claude/context/thrive/domains/

# Skills loaded
ls ~/.claude/skills/

# Mempalace config
python3 -m mempalace status
```
