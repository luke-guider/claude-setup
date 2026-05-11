# Memory Flow

How context survives between sessions and finds its way back into the next one.

This setup treats memory as a first-class tool, not a side effect. Three pieces work together so a session that started yesterday can pick up where it left off today without re-explaining anything:

1. **Workspace fragments** at `~/.claude/context/<workspace>/` — durable, versioned patterns and conventions for a workspace's domains and concerns.
2. **MemPalace** — semantic memory keyed by wing/hall/closet, populated automatically during sessions via hooks.
3. **Two Claude Code hooks** (`Stop`, `PreCompact`) that force the AI to save before context is lost.

This doc walks the loop end to end and defines the terminology.

---

## The Loop

```
                  ┌─────────────────────────────────────────────┐
                  │                                             │
                  ▼                                             │
  ┌──────────────────────────────┐                              │
  │ SessionStart hook            │                              │
  │ session-context.sh           │                              │
  │  → detects workspace + svc   │                              │
  │  → lists fragment file paths │                              │
  └──────────────┬───────────────┘                              │
                 │                                              │
                 ▼                                              │
  ┌──────────────────────────────┐                              │
  │ Layer 1: Claude reads        │                              │
  │  applicable fragments        │                              │
  │  (durable patterns/rules)    │                              │
  └──────────────┬───────────────┘                              │
                 │                                              │
                 ▼                                              │
  ┌──────────────────────────────┐                              │
  │ Layer 2: Claude queries      │                              │
  │  mempalace as needed         │                              │
  │  (deep, session-specific)    │                              │
  └──────────────┬───────────────┘                              │
                 │                                              │
                 ▼                                              │
  ┌──────────────────────────────┐                              │
  │ Stop hook fires every N      │                              │
  │ exchanges → AI saves diary + │                              │
  │ drawers (AI classifies)      │                              │
  └──────────────┬───────────────┘                              │
                 │                                              │
                 ▼                                              │
  ┌──────────────────────────────┐                              │
  │ PreCompact hook fires when   │                              │
  │ context is about to be       │                              │
  │ compressed → emergency save  │                              │
  └──────────────┬───────────────┘                              │
                 │                                              │
                 │   (later — new session opens)                │
                 └──────────────────────────────────────────────┘
```

Without the save hooks, the palace fills slowly and unevenly. With them, every session leaves the palace richer for the next.

---

## Terminology

| Term | What it is |
|---|---|
| **Wing** | Top-level partition of the palace, usually one per workspace (e.g. `workspace-a`, `workspace-a-frontend`, `workspace-b`). Defined in `~/.mempalace/wing_config.json`. |
| **Hall** | Category within a wing. Five default halls — `facts`, `discoveries`, `advice`, `events`, `preferences` — distinguish *what kind* of memory a drawer is (see `hall_keywords` in `~/.mempalace/config.json`). |
| **Closet** | Fine-grained grouping inside a hall (e.g. a feature, ticket, or specific subsystem). The AI picks one when saving. |
| **Drawer** | A single saved memory: a topic, decision, code snippet, or verbatim quote. Stored with wing + hall + closet metadata so search can scope tightly. |
| **Diary** | Per-session free-form log written alongside drawers. Captures narrative flow; drawers capture extractable facts. |
| **Tunnel** | A typed edge between two drawers in the knowledge graph (e.g. *decision X led to bug Y*). Lets you traverse related memories instead of relying on semantic search alone. |
| **Fragment** | A markdown file under `~/.claude/context/<workspace>/{domains,concerns}/`. Durable patterns, distinct from drawers (which are session artifacts). |
| **Workspace** | A logical project bucket. Each workspace gets its own fragment tree and one or more wings. |

Drawers vs fragments — the practical split:
- **Drawer** = "I learned this in *this* session, may or may not generalize". Created by the AI mid-conversation via the Stop/PreCompact hooks.
- **Fragment** = "this is now a permanent rule for this workspace". Manually promoted by you (see `adding-fragments.md`).

---

## Layer 0 — SessionStart

`claude/hooks/session-context.sh` runs at session start, before the first prompt. It:

1. Reads the CWD and current branch.
2. Walks `~/.claude/context/` for a directory whose name appears in the CWD (case-insensitive). That's the **workspace**.
3. Detects a **service path** from common subdirectory patterns (`apps/`, `services/`, `packages/`, `functions/`) or branch-name hints.
4. Prints a tight Working Context block listing applicable domain + concern fragment **paths only** — not their content. Claude reads them on demand.

Output is ~500 bytes. The Claude session sees what's available but pays no token cost for fragments it doesn't end up using.

---

## Layer 1 — Fragments (on demand)

Each workspace has a fragment tree:

```
~/.claude/context/<workspace>/
  domains/
    frontend.md
    api.md
    ...
  concerns/
    queue-patterns.md
    db-tenancy.md
    ...
```

Each fragment is small (500–2000 bytes) and tagged with frontmatter (`domains`, `services`, `concerns`, `applies_to`). The global `~/.claude/CLAUDE.md` instructs Claude to read the listed fragment files before writing code in the matched domain.

Fragments are durable. They live in git (or git-ignored if private, as in this repo's setup), they evolve as patterns crystallize, and they apply across sessions.

See `adding-fragments.md` for fragment authoring and the lifecycle (when a drawer learning earns promotion to a fragment).

---

## Layer 2 — MemPalace

For implementation specifics — exact schemas, prior bug reports, decision rationale, code patterns spotted in old reviews — Claude calls the MemPalace MCP. Tools available include:

- `mempalace_search` — semantic search, optionally scoped to a wing/hall/closet
- `mempalace_kg_query`, `mempalace_kg_timeline` — graph traversal across drawer tunnels
- `mempalace_diary_read` — read past session diaries
- `mempalace_find_tunnels`, `mempalace_traverse` — follow typed edges between drawers
- `mempalace_list_wings`, `mempalace_list_rooms`, `mempalace_status` — discovery

These queries are scoped, not flat. When Layer 0 sets the working wing, Layer 2 queries default to it.

---

## The Save Hooks — How Drawers Get Created

This is what makes memory persist between sessions. Two hooks live in `mempalace/hooks/`:

### `mempal_save_hook.sh` (Claude Code `Stop` hook)

Fires after every assistant response. Behavior:

1. Counts human messages in the session transcript.
2. Every `SAVE_INTERVAL` messages (default 15), returns `decision: "block"` with a `reason` that instructs the AI to save key topics, decisions, code, and verbatim quotes.
3. The AI does the classification — picks wing, hall, closet — because it has the conversation context. No regex, no keyword rules.
4. When the AI tries to stop again, `stop_hook_active=true` flag prevents an infinite loop.

This is "diary + drawers, on a cadence, by the AI itself." The hook does no parsing of conversation content; it just forces the AI to save.

### `mempal_precompact_hook.sh` (Claude Code `PreCompact` hook)

Fires right before Claude Code compresses the conversation to free context. Always blocks — compaction is the moment detailed context is most at risk of being lost.

The block reason tells the AI to be *thorough*: save everything that won't survive compaction, then let compaction proceed.

### Wiring

Both scripts have their install snippets in their header comments. Add them to `~/.claude/settings.local.json` (Claude Code) or `~/.codex/hooks.json` (Codex CLI). They are not auto-installed by `install.sh` because hook registration is per-machine and the script paths are absolute.

State and logs land in `~/.mempalace/hook_state/` (gitignored). Tail `hook.log` to see when the hook fires.

---

## Mining — Bulk-Loading Code into the Palace

Hooks save *conversation* memories. Mining loads *code* memories.

`mempalace/mine/mine-workspace.example.sh` is a template that rsyncs a workspace's relevant subtrees into a temp dir and runs `python3 -m mempalace mine` against it, tagged with the wing name. Drawers from mining represent code patterns, function signatures, and structure. Claude can then search them at Layer 2.

You run mining manually after large refactors or new feature work that you want indexed. Saved drawers from the hook complement these — the AI captures *decisions and discoveries*, mining captures *what the code looks like*.

---

## Putting It Together

A practical timeline for a task spanning two sessions:

**Session 1 (Mon):**
- SessionStart resolves workspace `workspace-a` from `~/REPOS/workspace-a/...`.
- Working Context lists `workspace-a/domains/frontend.md` and `workspace-a/concerns/queue-patterns.md`.
- Claude reads the fragments, starts work, queries `mempalace_search --wing workspace-a` once or twice for older patterns.
- After 15 human messages the Stop hook fires. The AI saves drawers: a *decision* in hall_advice ("use the message-batching wrapper not the raw publisher"), a *fact* in hall_facts ("queue X requires deduplication keys"), a *discovery* in hall_discoveries.
- Session ends or compacts. PreCompact (if it fired) ensured everything was saved.

**Session 2 (Tue, same workspace):**
- SessionStart resolves the same workspace.
- Claude reads the same fragments. They haven't changed — but the palace has.
- A `mempalace_search` call surfaces Monday's drawers: the decision, the fact, the discovery.
- Today's task starts from "we already decided X" rather than re-debating it.

If Monday's discovery turns out to be a permanent rule, you promote it from a drawer to a fragment (`adding-fragments.md`). Now it's loaded automatically at Layer 1 for every future session in this workspace.

---

## See Also

- `docs/architecture.md` — the three-layer progressive disclosure model
- `docs/adding-fragments.md` — how to write fragments and when to promote a drawer
- `docs/backup-restore.md` — backing up the palace
- `mempalace/hooks/mempal_save_hook.sh` — full install snippet in the header comment
- `mempalace/hooks/mempal_precompact_hook.sh` — same
