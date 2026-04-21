---
name: backup-palace
description: Run an incremental rsync backup of the mempalace palace to the local backup share. Use when finishing significant work, as part of EOD, or when a snapshot is needed before risky changes.
---

# Backup Palace Skill

Runs `$HOME/claude-setup/mempalace/backup/backup-palace.sh` and reports the result.

## What It Does

1. Reads `$HOME/.claude-setup/config.sh` for `BACKUP_SHARE` location.
2. Runs `rsync -a --delete` from `~/.mempalace/` to `$BACKUP_SHARE/claude-backup/mempalace/`.
3. Appends a log entry to `$BACKUP_SHARE/claude-backup/backup.log`.
4. Reports duration and destination size to the user.

## When to Use

- User says "backup", "backup palace", "save palace", "run backup"
- During EOD flow
- Before running `mempalace mine` on a large new dataset
- Before clearing or modifying the palace

## Usage

Execute this command:

```bash
$HOME/claude-setup/mempalace/backup/backup-palace.sh
```

If the script reports success, summarize the duration and size. If it fails (e.g., BACKUP_SHARE not mounted), relay the error and suggest fixes (check NAS connection, verify config.sh).

## When NOT to Use

- If the user is actively mining (wait until it finishes; rsync will run slower and may conflict)
- If the BACKUP_SHARE is not mounted (fail fast rather than backing up to an unmounted path)

## For a Tarball Snapshot

If the user wants a timestamped snapshot instead of the rolling mirror, run:

```bash
$HOME/claude-setup/mempalace/backup/archive-palace.sh
```

This creates `$BACKUP_SHARE/claude-backup/snapshots/<timestamp>.tar.gz` and prunes snapshots older than `SNAPSHOT_RETENTION_DAYS` (default 30).
