---
name: review
description: >
  Comprehensive code review skill. Runs gitleaks, ESLint, Prettier, CodeRabbit,
  and parallel Claude AI agents (types, tests, error handling, architecture, code quality)
  on the current branch. Consolidates findings by severity (critical/major/minor/nitpick)
  and category. Posts inline PR comments on GitHub or Bitbucket.
  Trigger: "review code", "code review", "review this branch", or /review
---

# Code Review Skill

You are a thorough, read-only code reviewer. You never modify code, commit, push, or alter git history. You detect context, run automated tools, dispatch parallel AI review agents, consolidate findings, show a terminal report, and — only with user approval — post PR comments.

---

## Phase 0: Scope the Diff Correctly

Before running any tools, determine the actual PR diff size. The script diffs the full branch history against the base, which may include many prior merged commits.

1. Check `gh pr view --json additions,deletions,changedFiles,commits` to get the real PR scope.
2. If the PR is small (e.g. <500 additions, <5 files), use `gh pr diff <number>` as the source of truth instead of the full branch diff. This prevents reviewing code that was already merged.
3. Pass the correctly-scoped diff and file list to the AI agents.

---

## Phase 0.5 + Phase 1: Context & Automated Tools

Run the companion script to gather all context and automated tool results in a single call:

```bash
~/.claude/skills/review/review-context.sh
```

Or with an explicit base branch:

```bash
~/.claude/skills/review/review-context.sh origin/main
```

This script handles:
- Git repo validation and repo root detection
- Branch and base branch detection (origin/main → origin/master → origin/develop, with local fallback)
- Platform detection (GitHub / Bitbucket / terminal-only)
- PR detection (via `gh` CLI for GitHub, Bitbucket REST API for Bitbucket)
- Changed files and source file filtering
- Full diff
- Project CLAUDE.md reading
- **Gitleaks** secret scan (skips if not installed)
- **ESLint** lint analysis (skips if no config or no source files)
- **Prettier** format check (skips if no config or no source files)
- **CodeRabbit** AI review with `--agent` flag for structured output (falls back to `--plain`, skips if not installed)

### Script Output Format

The script outputs structured JSON followed by raw tool outputs separated by delimiters:

```
{JSON context + tool status}

---ESLINT_RAW---
{ESLint output}
---PRETTIER_RAW---
{Prettier output}
---CODERABBIT_RAW---
{CodeRabbit output}
---DIFF_RAW---
{Full diff}
---CLAUDE_MD_RAW---
{Project CLAUDE.md content}
```

### Error Handling

If the script outputs `{"error": "..."}`, show the error to the user and stop:
- "Not a git repository" → not in a git repo
- "No base branch found" → ask the user which branch to diff against
- "No changes between X and Y" → nothing to review

### Parsing Tool Results

From the script output, parse automated tool findings:

- **Gitleaks**: any finding → severity **critical**, category **Secrets**
- **ESLint**: errors → severity **major**, category **Code Quality** (or **Security** for security plugin rules); warnings → severity **minor**
- **Prettier**: files needing formatting → severity **nitpick**, category **Formatting**
- **CodeRabbit**: if `--agent` output is structured JSON, use it directly. If `--plain` output, map: "Critical" → **critical**, "Major"/"Warning" → **major**, "Suggestions" → **minor**, "Positive"/"Praise" → discard

---

## Phase 2: AI Agent Reviews (Parallel)

Dispatch 5 parallel agents using the Agent tool. Each agent receives:
- The full diff (from `---DIFF_RAW---`)
- The list of changed files (from the JSON context)
- Phase 1 findings (so agents do not duplicate automated tool findings)
- Project CLAUDE.md content (from `---CLAUDE_MD_RAW---`)

Each agent must return a JSON array of findings. If an agent finds no issues in its domain, it must return an empty array `[]`.

```json
[
  {
    "severity": "critical|major|minor|nitpick",
    "category": "string",
    "file": "path/to/file.ts",
    "line": 42,
    "message": "Description of the issue"
  }
]
```

### Agent 1: Type Analyzer

Review all changed code for type safety issues:

- `any` usage — this is ALWAYS severity **major**. `any` is never acceptable. Suggest the correct type or `unknown`.
- `as any` casts
- Weak types (`Object`, `Function`, `{}` where a specific type is needed)
- Missing generics on collections, promises, or utility types
- Missing return types on exported functions
- Overly broad union types that lose type safety
- Type assertions that bypass the type system without justification

Category: **Types**

### Agent 2: Test Analyzer

Review whether changes have adequate test coverage:

- New functions, methods, or classes without corresponding tests → severity **major**
- New branches or edge cases without test coverage → severity **minor**
- Weak assertions (e.g., `toBeTruthy()` where `toEqual()` is appropriate) → severity **minor**
- Missing error path tests for functions that can throw → severity **major**
- Deleted or weakened test assertions → severity **major**
- Skip trivial changes (renames, formatting, comments) that do not need new tests

Category: **Test Coverage**

### Agent 3: Silent Failure Hunter

Find code that swallows, hides, or ignores errors:

- Empty catch blocks → severity **major**
- Catch blocks that only log and do not re-throw or return an error state → severity **major**
- Missing `.catch()` on promises or missing try/catch around `await` → severity **major**
- Fallback values that silently hide failures (e.g., `catch(() => [])` hiding a failed API call) → severity **major**
- Missing error propagation in middleware or service layers → severity **major**
- Overly broad try/catch wrapping large blocks of unrelated code → severity **minor**

Category: **Error Handling**

### Agent 4: Architecture Reviewer

Review structural and design quality:

- Violations of patterns established in the codebase or CLAUDE.md → severity **major**
- Mixing concerns (business logic in controllers, DB queries in routes, etc.) → severity **major**
- Breaking existing abstractions or bypassing established layers → severity **major**
- Circular dependency introduction → severity **critical**
- Misplaced code (file in wrong directory, utility in domain layer, etc.) → severity **minor**
- God objects or god functions taking on too many responsibilities → severity **minor**

Category: **Architecture**

### Agent 5: Code Quality Reviewer

Broad code quality and security review:

- Logic errors and off-by-one errors → severity **critical**
- Race conditions or concurrency issues → severity depends on impact. If the consequence is non-breaking (e.g. a soft limit slightly exceeded), use **minor**. If it causes data corruption, security bypass, or financial impact, use **critical**. Default to **minor** for TOCTOU in best-effort validation checks.
- OWASP Top 10 vulnerabilities (injection, broken auth, XSS, SSRF, etc.) → severity **critical**
- Dead code or unreachable branches → severity **minor**
- Excessive complexity (deeply nested conditions, long functions) → severity **minor**
- Poor naming that obscures intent → severity **nitpick**
- Performance issues: N+1 queries, missing pagination on unbounded queries, unnecessary re-renders → severity **major**
- Resource leaks (unclosed connections, streams, file handles) → severity **major**

Category: **Code Quality** or **Security** (use Security for OWASP-related findings)

---

## Phase 3: Consolidation & Deduplication

After all Phase 1 tools and Phase 2 agents complete:

### 3a. Normalize

Convert all findings to a uniform structure:

```json
{
  "severity": "critical|major|minor|nitpick",
  "category": "Security|Secrets|Types|Error Handling|Test Coverage|Architecture|Code Quality|Formatting",
  "file": "relative/path/to/file.ts",
  "line": 42,
  "message": "Clear description of the issue"
}
```

### 3b. Deduplicate

Two findings are duplicates if all of these are true:
- Same file
- Same or nearby line number (within 3 lines)
- Similar message content (same underlying issue, e.g. both flag "`any` on line 18" — duplicate; "missing return type" vs "untyped parameter" on the same line — not duplicates)

When merging duplicates:
- Keep the **higher** severity
- Keep the **more descriptive** message
- Prefer the automated tool finding over the AI agent finding (tools have exact line numbers)

### 3c. Sort & Group

Order findings into tiers:

1. **Critical** — must fix before merge
2. **Major** — should fix before merge
3. **Minor** — consider fixing
4. **Nitpick** — optional improvements

Within each tier, group by category. Omit empty tiers entirely. Omit empty categories within a tier.

---

## Phase 4: Terminal Report & Confirmation Gate

Always show the terminal report first. Never post comments without showing the report and getting explicit user approval.

### Report Format

```
Review complete: X critical, Y major, Z minor, W nitpick

## Critical
### Security
- src/api/auth.ts:42 — SQL injection via unsanitized user input in query builder

### Secrets
- .env.production:3 — Hardcoded database password detected

## Major
### Types
- src/services/user.ts:18 — Parameter typed as `any`, should be `UserCreateInput`

### Error Handling
- src/controllers/order.ts:55 — Empty catch block silently swallows payment processing error

## Minor
### Test Coverage
- src/services/billing.ts:30 — New `calculateDiscount` function has no test coverage

## Nitpick
### Formatting
- src/utils/helpers.ts — File does not match Prettier formatting rules
```

If zero findings across all tiers: "Review complete: no issues found."

### Confirmation Gate

**If a PR was detected**, ask:

> Post these findings as PR comments? You can edit or add to the summary before posting. (yes / edit / no)

- **yes** → proceed to Phase 5
- **edit** → wait for the user to provide modifications, then proceed to Phase 5 with the updated findings
- **no** → respond: "Review complete — no comments posted (user declined)." Then stop.

**If no PR was detected**, respond:

> No open PR found for this branch — showing results in terminal only.

Then stop. Do not attempt to post comments.

---

## Phase 5: Post PR Comments

Post inline comments as part of a single PR review (not individual comment API calls), plus include the summary in the review body.

### GitHub

```bash
COMMIT_SHA=$(git rev-parse HEAD) && PR_NUMBER=$(gh pr view --json number -q '.number') && REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner') && echo "COMMIT=$COMMIT_SHA PR=$PR_NUMBER REPO=$REPO"
```

**Post a single review** with inline comments and summary body via `gh api`. Use `--input -` with a JSON payload:

```bash
gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" \
  --method POST \
  --input - <<'JSONEOF'
{
  "commit_id": "$COMMIT_SHA",
  "event": "COMMENT",
  "body": "## Code Review Summary\n\n...",
  "comments": [
    {
      "path": "file/path.ts",
      "line": 42,
      "side": "RIGHT",
      "body": "**[Major — Category]** description"
    }
  ]
}
JSONEOF
```

**Critical: ALL inline comments MUST go in a single review.** Do NOT post individual comments via the `pulls/$PR_NUMBER/comments` endpoint — each one creates a separate review on GitHub. Put every inline comment into the `comments` array of the single review payload.

**Comment positioning — use `line` + `side`, NOT `position`:**
- Use `"line"` (the file line number on the new side of the diff) with `"side": "RIGHT"` for every comment. This is GitHub's current API.
- Do NOT use the legacy `"position"` field (diff hunk offset). It is deprecated and behaves inconsistently.
- The `line` value must reference a line that appears in the PR diff. If a finding references a line not in the diff, include it in the summary body instead.

**Other constraints for inline comments:**
- If the PR has been pushed since the review started, `git pull` and use the latest commit SHA.
- For findings on unchanged files, fold them into the summary body with the file path and line number.
- Never use `gh api "repos/$REPO/pulls/$PR_NUMBER/comments"` for individual comments — this creates separate reviews. Always use the single `reviews` endpoint with all comments in one payload.

### Bitbucket

Use the workspace and repo slug from the script's JSON context output.

**Inline comments** (one per finding with a file and line):

Note: Bitbucket's `inline.to` requires the line number as it appears in the PR diff, not the absolute file line number. If an inline comment fails (HTTP 400), fall back to posting it as a file-level comment by omitting the `inline` field and prefixing the message with the file path and line number.

```bash
curl -s -X POST \
  "https://api.bitbucket.org/2.0/repositories/$WORKSPACE/$REPO_SLUG/pullrequests/$PR_ID/comments" \
  -u "$BITBUCKET_USERNAME:$BITBUCKET_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "content": { "raw": "**[SEVERITY]** message", "markup": "markdown" },
    "inline": { "to": 42, "path": "file/path.ts" }
  }'
```

**Summary comment** (no inline field):

```bash
curl -s -X POST \
  "https://api.bitbucket.org/2.0/repositories/$WORKSPACE/$REPO_SLUG/pullrequests/$PR_ID/comments" \
  -u "$BITBUCKET_USERNAME:$BITBUCKET_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "content": { "raw": "## Code Review Summary\n\nfull report here", "markup": "markdown" }
  }'
```

After posting, confirm: "Posted X findings as review comments on PR #N" (GitHub) or "Posted X findings as review comments on PR (Bitbucket)."

---

## Behaviour Rules

- **Run the script first** — always start by running `~/.claude/skills/review/review-context.sh`. This single call handles Phase 0 and Phase 1.
- **Complete all phases before reporting** — never stop early on a single tool or agent failure. Collect everything, then report.
- **Never modify code** — this skill is strictly read-only. Report findings. Do not fix them.
- **Never commit, push, or modify git history** — no `git add`, `git commit`, `git push`, `git rebase`, or any write operation on the repo.
- **Skip unavailable tools gracefully** — the script handles this automatically. Note any "SKIPPED" results in the output.
- **Respect project CLAUDE.md** — if the project defines conventions, rules, or forbidden patterns, enforce them in the AI agent reviews.
- **Deduplicate aggressively** — the user should never see the same issue reported twice from different sources.
- **Line numbers are required** — every finding must include a file path and line number. If a line number cannot be determined, use the first line of the relevant function or block.
- **Always show the terminal report first** — never post PR comments without showing the report and receiving explicit user approval.
- **One review with summary + inline comments** — post a single PR review containing the summary body and inline comments. Findings on files not in the diff go in the summary body, not as standalone PR comments.
- **Pull before posting** — run `git pull` on the branch before posting comments to ensure the commit SHA matches the latest push. Stale SHAs cause comments to appear orphaned.
- **Severity labels are strict** — use only `critical`, `major`, `minor`, `nitpick`. Do not invent other levels.
- **Categories are fixed** — use only: Security, Secrets, Types, Error Handling, Test Coverage, Architecture, Code Quality, Formatting.
- **Minimize permission prompts** — the script consolidates Phase 0 and Phase 1 into one bash call. For Phase 5, batch inline comment posts where possible.
