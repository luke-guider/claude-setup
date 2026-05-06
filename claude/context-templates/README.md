# Context Templates

These are skeleton templates for domain fragments and cross-cutting concern fragments used by the `session-context.sh` hook.

## How to Use

1. Run `./install.sh` — if `claude/context/` doesn't exist in the repo, these templates are copied to `~/.claude/context/`
2. Edit the copied files in `~/.claude/context/` with your own domain-specific content
3. Remove `workspace-a` / `workspace-b` names and replace with your actual workspace names
4. Re-run `./install.sh --update` after editing

## Structure

```
claude/context/
  workspace-a/
    domains/
      _template.md    ← copy this for each domain
    concerns/
      _template.md    ← copy this for each cross-cutting concern
  workspace-b/
    ...
```

## Frontmatter Format

Domain fragments:
```yaml
---
domains: [domain-name]
services: [service-name]
concerns: [concern-tag]
---
```

Concern fragments:
```yaml
---
concerns: [concern-name]
applies_to: [service-a, service-b]
---
```

## When to Add New Fragments

- A new service is created → add a domain fragment
- A pattern spans multiple services → add a concern fragment
- A convention changes → update the relevant fragment
