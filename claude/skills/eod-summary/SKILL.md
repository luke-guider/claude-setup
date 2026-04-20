---
name: eod-summary
description: End-of-day summary of all active Claude Code sessions. Shows what each session is working on, its project path, git branch, and the resume command. Formatted as markdown. Use when "end of day", "eod", "wrap up", "session summary", or /eod-summary is invoked.
---

# End-of-Day Session Summary

Scan all recent Claude Code sessions and produce a markdown handoff summary so work can be resumed tomorrow. Automatically copy the result to the clipboard via `pbcopy`.

## Procedure

### Step 1: Discover Sessions

Find all session `.jsonl` files modified in the last 24 hours (excluding subagent files):

```bash
find ~/.claude/projects -maxdepth 2 -name "*.jsonl" ! -path "*/subagents/*" -mmin -1440 2>/dev/null
```

For each file, extract:
- **Project name** from the path (the segment after `projects/`, decoded from the path-encoded format e.g. `-Users-lukebeach-REPOS-Thrive-frontend` → `Thrive-frontend`)
- **Session ID** from the filename (strip `.jsonl`)
- **Last modified time** via `stat`
- **Working directory** from the first line of the jsonl (`cwd` field) — this is the actual path the session was running in

### Step 2: Extract Session Context

For each session, extract user messages (type `"user"`, NOT `"human"`) to determine what the session was working on:

```bash
grep '"type":"user"' <session_file> | head -5
```

Parse the JSON to get the text content of each user message. Ignore system-reminder tags, command tags, and hook output — focus on actual user messages.

Also check the git state for each project directory (using the `cwd` from step 1):

```bash
git -C <project_path> branch --show-current 2>/dev/null
git -C <project_path> status --short 2>/dev/null | head -10
git -C <project_path> log --oneline -3 2>/dev/null
```

### Step 3: Determine Active vs Stale

Group sessions by project. For projects with multiple sessions, only show the most recently modified one (it's the active one). Mark sessions with status emoji:
- 🟢 **Active** — modified within the last 2 hours
- 🟡 **Recent** — modified 2-12 hours ago
- ⚪ **Stale** — modified 12-24 hours ago (include but de-emphasize)

### Step 4: Generate Summary

Output must use **standard markdown** formatting.

Format:

```
## 🌙 End of Day — <date>

---

### 🟢 <Project Name>
- 🌿 Branch: `<branch>`
- 💬 <1-2 sentence summary of what was being worked on>
- 📝 <uncommitted changes status — "Clean" or brief description>
- ▶️ Resume: `cd <path> && claude --continue`

---

(repeat for each project)

---

### 📋 Quick Resume
```
# <project 1>
cd <path1> && claude --continue
# <project 2>
cd <path2> && claude --continue
```
```

### Step 5: Copy to Clipboard

After displaying the summary, pipe the full output to `pbcopy` so it's ready to paste.

### Formatting Details

- Use `---` horizontal rules as section separators
- Keep summaries to one line per field
- The quick resume block at the bottom should be a single code block with all commands
- Use the actual filesystem path from the session's `cwd`, not a decoded guess from the project key
- For uncommitted changes, keep it brief: "Clean" / "4 untracked files" / "12 modified package.json files" etc.

## Rules

- *Read-only*: Never modify session files, git state, or any project files.
- *Privacy-aware*: Only show the topic/intent of work, not full message content. Don't dump raw conversation text.
- *Skip this session*: Exclude the current active session from the summary (the user is already in it).
- *No guessing*: If you can't determine what a session was doing from the messages, say "Unable to determine — check session directly".
- *Include git context*: Branch name and recent commits help jog memory more than raw message content.
- *Clipboard*: Always copy the final summary to clipboard via `pbcopy` after displaying it.
