# Backup and Restore

## Why Backup

The mempalace palace contains ~2.2M drawers (verbatim code chunks) built via hours of mining. If lost, remining takes 6+ hours. The palace is not in the git repo (too large, sensitive).

## Destination

Whatever you set as `BACKUP_SHARE` in `~/.claude-setup/config.sh` — typically:

- NAS mount (`/Volumes/NAS`)
- External drive (`/Volumes/Backup`)
- Synced cloud folder (`$HOME/Dropbox`, `$HOME/Library/Mobile Documents/...`)

Structure at the destination:

```
$BACKUP_SHARE/claude-backup/
├── mempalace/              # rsync mirror
├── snapshots/
│   ├── 2026-04-17-143022.tar.gz
│   └── ...
└── backup.log              # timestamped log
```

## Two Flows

### Incremental (rsync mirror)

Fast, incremental. Keeps one up-to-date copy.

```bash
./mempalace/backup/backup-palace.sh
```

Timing: seconds if palace unchanged, minutes after heavy mining.

### Snapshot (tarball)

Point-in-time archive. Auto-prunes old snapshots.

```bash
./mempalace/backup/archive-palace.sh
```

Timing: ~1-3 minutes for the full palace. Prunes snapshots older than `SNAPSHOT_RETENTION_DAYS` (default 30).

## Triggers

### Manual

```bash
./mempalace/backup/backup-palace.sh    # rsync
./mempalace/backup/archive-palace.sh   # tarball
```

### Skill

In any Claude Code session: `/backup-palace` runs the rsync flow.

### SessionEnd Hook (opt-in at install)

Fires `backup-palace.sh` in background every session end. Zero lag because rsync with no changes is fast.

### Scheduled (opt-in at install)

launchd plist at `~/Library/LaunchAgents/com.claude-setup.mempalace-backup.plist`. Runs weekly Sunday 03:00.

## Restore

### From rsync mirror

```bash
./mempalace/backup/restore-palace.sh
```

Prompts for confirmation before overwriting.

### From tarball snapshot

```bash
./mempalace/backup/restore-palace.sh $BACKUP_SHARE/claude-backup/snapshots/2026-04-17-143022.tar.gz
```

## Verification

```bash
python3 -m mempalace status
```

Should show all wings with expected drawer counts (~90k frontend, ~1.5M guider, ~177k thrive).

## What's Excluded from Backup

- `hook_state/` — runtime state, no value
- `hooks/` — already in the setup repo
- `mine-*.sh` — already in the setup repo

## Recovery Scenarios

**Corrupted palace**: Run `restore-palace.sh` from the rsync mirror. If the mirror was also affected, use the most recent snapshot.

**Fresh machine**: After running `install.sh`, the installer checks for `$BACKUP_SHARE/claude-backup/mempalace/` and offers to restore automatically.

**Pre-risky-change**: Run `archive-palace.sh` before the change. Restore from that specific snapshot if needed.
