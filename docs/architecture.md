# Architecture

## Three-Layer Context System

This setup implements progressive disclosure — context loads based on what the user is working on, not upfront.

### Layer 0 — Session Start (~500 bytes)

The `session-context.sh` hook (in `~/.claude/hooks/`, symlinked from repo) runs on SessionStart. It:

1. Reads CWD and git branch
2. Detects workspace (Thrive vs Guider) and specific service
3. Resolves dependencies from `docs/service-graph.toml`
4. Outputs a block with:
   - Working service name and domain
   - Mempalace wing/room
   - Connected services (from graph)
   - Applicable fragment file paths (NOT their content)
   - Cross-project references (Thrive↔Guider)

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

### Thrive

10 domain fragments covering: mentoring, content, user, gateway, ai, tenant, communication, goals, frontend, infra.

6 concern fragments covering: sqs-patterns, mongodb-tenancy, auth-middleware, error-handling, testing-patterns, graphql-codegen.

### Guider

5 domain fragments covering: admin, api, bot, front-end, sanity.

3 concern fragments covering: rush-workflows, shared-packages, azure-functions.

## Service Graphs

`docs/service-graph.toml` in the Thrive repo enumerates 92 services with their dependencies and mempalace locations. A similar graph exists for the Guider Rush monorepo (59 projects).

The hook reads these graphs to answer "what depends on content-core?" at session start.

## MemPalace Integration

The palace stores verbatim code chunks from all three wings (thrive, thrive-frontend, guider). Layer 0 tells Claude the wing/room to use for scoped searches.

Mempalace MCP is registered at user level so it's available in every project.

## Token Budget

| Phase | Size |
|---|---|
| Auto-loaded (global + project CLAUDE.md) | ~14KB |
| Layer 0 (SessionStart output) | ~500 bytes |
| Layer 1 (task-scoped fragments) | ~3-6KB |
| Layer 2 (mempalace queries) | on-demand, scoped to result count |

Total typical session: ~17-20KB. Down from ~36KB flat-loaded.
