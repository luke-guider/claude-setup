# Architecture

## Three-Layer Context System

This setup implements progressive disclosure — context loads based on what the user is working on, not upfront.

### Layer 0 — Session Start (~500 bytes)

The `session-context.sh` hook (in `~/.claude/hooks/`, symlinked from repo) runs on SessionStart. It:

1. Reads CWD and git branch
2. Detects which workspace and specific service from the CWD path
3. Resolves dependencies from `docs/service-graph.toml`
4. Outputs a block with:
   - Working service name and domain
   - Mempalace wing/room
   - Connected services (from graph)
   - Applicable fragment file paths (NOT their content)
   - Cross-workspace references (when one workspace depends on another)

Fragment paths are listed but NOT loaded at this stage.

### Layer 1 — Task Identified (~3-6KB)

The global `~/.claude/CLAUDE.md` instructs Claude to read the fragment files listed in Working Context before writing code. Fragment files are small, tagged markdown with domain-specific patterns.

When the user describes a task, Claude:
1. Identifies involved domain(s)
2. Reads those domain fragments + cross-cutting concern fragments
3. For cross-service tasks, reads fragments for all involved domains

### Layer 2 — Deep Detail (on demand)

For implementation specifics (exact schemas, function signatures, prior patterns), Claude uses `mempalace_search` scoped to the relevant wing/room.

## Fragment Library

Each workspace gets its own fragment tree under `claude/context/<workspace>/`:

- `domains/` — one markdown file per business domain (e.g., `frontend.md`, `api.md`, `auth.md`). Captures the patterns, conventions, and gotchas specific to that domain.
- `concerns/` — one file per cross-cutting topic that spans domains (e.g., `queue-patterns.md`, `db-tenancy.md`, `error-handling.md`).

Fragment count scales with the workspace — typically 5–10 domain fragments and 3–6 concern fragments per workspace. Fragments stay small (500–2000 bytes) and link out to mempalace for deep detail.

## Service Graphs

A `docs/service-graph.toml` (or equivalent) inside each workspace repo enumerates services with their dependencies and mempalace locations. The hook reads this graph to answer "what depends on service X?" at session start.

## MemPalace Integration

The palace stores verbatim code chunks per workspace wing. Layer 0 tells Claude the wing/room to use for scoped searches.

Mempalace MCP is registered at user level so it's available in every project.

## Token Budget

| Phase | Size |
|---|---|
| Auto-loaded (global + project CLAUDE.md) | ~14KB |
| Layer 0 (SessionStart output) | ~500 bytes |
| Layer 1 (task-scoped fragments) | ~3-6KB |
| Layer 2 (mempalace queries) | on-demand, scoped to result count |

Total typical session: ~17-20KB. Down from ~36KB flat-loaded.
