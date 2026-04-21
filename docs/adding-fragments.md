# Adding Context Fragments

Context fragments are the Layer 1 of the progressive disclosure system. Each fragment is a small markdown file with frontmatter tags and domain-specific patterns.

## When to Add a Fragment

- You've hit the same review feedback multiple times (e.g., frontend review rules)
- You've learned a non-obvious pattern in a specific domain
- You've onboarded a new team member and explained a pattern you realize isn't documented

## Where to Put It

### Domain fragment

File: `claude/context/{thrive|guider}/domains/<domain>.md`

Use when the pattern applies to a specific domain (e.g., all mentoring code, all frontend code).

### Concern fragment

File: `claude/context/{thrive|guider}/concerns/<concern>.md`

Use for cross-cutting patterns that apply to multiple domains (e.g., SQS usage, MongoDB tenancy, error handling).

## Fragment Format

```markdown
---
domains: [mentoring]
services: [mentorship-core, mentorship-core-pipelines]
concerns: [sqs, mongodb, dual-cluster]
---

# Mentoring Domain

## Specific Pattern 1

Explanation and code example.

## Specific Pattern 2

Another pattern.
```

### Frontmatter Keys

- **`domains`** — business domains this applies to. Matches domain detection in `session-context.sh`.
- **`services`** — specific service names this applies to.
- **`concerns`** (for domain fragments) — cross-cutting topics covered. Helps the hook decide whether to include related concern fragments.
- **`applies_to`** (for concern fragments) — which domains or service classes this concern applies to.

## Keep It Short

- Target 500-2000 bytes per fragment
- Link to mempalace search for deep detail rather than duplicating code
- If a fragment grows past 3KB, consider splitting into sub-fragments

## After Adding

Since fragments are symlinked from the repo, no install step is needed. The file is immediately available in `~/.claude/context/...`.

Commit the new fragment:

```bash
cd ~/claude-setup
git add claude/context/
git commit -m "docs(context): add <domain> <concern> fragment"
```

## Verifying the Hook Picks It Up

Start a new Claude Code session in the relevant service directory. The Working Context output should list your new fragment under "Applicable Rules" if the domain matches.

If it doesn't appear, check:
1. Frontmatter `domains:` tag matches what `session-context.sh` returns for that service
2. For concern fragments: the `applies_to:` list includes the domain

The hook's domain detection logic is in `claude/hooks/session-context.sh` — update the mapping functions (`service_to_domain_thrive`) if you add services to an existing domain or introduce new domains.
