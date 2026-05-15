---
name: qa-self-review
description: >
  Use after implementing or modifying code in the current session to validate your own work
  end-to-end with qa-bot. Inventories what changed, recovers intent from session + linked
  Jira/GitHub ticket, derives honest acceptance criteria, dispatches a subagent to write+run
  e2e tests via qa-bot's MCP tools, renders an HTML report, and (with approval) posts a
  structured PR comment. Bias: low trust in own assertions, test the cases you skipped.
  Trigger: "qa my changes", "qa my work", "self-review", "test what I just built",
  or /qa-self-review
---

# qa-self-review

You just wrote or modified code. Now you validate it. Treat your own claims with low trust — exercise the edge cases you didn't bother handling first time round.

## Prerequisites — verify first, stop if any fail

- Target repo has `qa-bot.config.ts` at its root.
- `gh auth status` shows logged-in and has access to the PR's repo.
- The 21 `qa_*` MCP tools are available in this session.

If any prerequisite fails, report exactly what's missing and stop. Don't work around it.

---

## Phase 1: Inventory what changed

1. `git diff <base>...HEAD --stat` (base usually `origin/main`) — list changed files.
2. Group by surface: HTTP route, UI component, mobile screen, background job, config.
3. Note which surfaces already have e2e coverage in the project's `tests/` dir and which don't.

## Phase 2: Recover intent

The session has the *actual* intent. The ticket has the *claimed* intent. Both matter.

1. **Session intent** — restate what the user asked for, what edge cases you raised, what you skipped and why. Use the conversation, not your imagination.
2. **Ticket intent** — if there's a linked Jira or GitHub ticket:
   - GitHub PR: `gh pr view <num> --json title,body,labels,linkedIssues`
   - Jira ticket: Atlassian MCP `getJiraIssue` (the agent handles auth — don't try to manually wire it)
3. If session intent and ticket disagree, the session wins (user is in front of you), but flag the disagreement so it lands in the PR comment.

## Phase 3: Derive acceptance criteria

Produce an `acceptanceCriteria` array matching `qa_pr_post_report`'s schema: `{ id?, text, status, note? }`.

Be honest:
- One entry per case the user explicitly asked for.
- One entry per obvious edge case the changed code touches (empty state, error path, auth boundary, concurrency if relevant).
- Default every status to `blocked` until the subagent proves it. Do NOT pre-fill `passed`.
- If you implemented something but skipped a known edge case, include it with status `skipped` and a `note` explaining why.

## Phase 4: Dispatch the QA subagent

Dispatch an Agent (subagent_type: `general-purpose`). Pass it the full AC list and a one-paragraph summary so it doesn't re-derive them.

Brief:

```
You are a QA subagent. Validate work I just finished on branch <BRANCH> in <TARGET-REPO-PATH>.

Acceptance criteria — verify each against actual test outcomes; do NOT trust my labels,
set status from what tests show:

<AC LIST as JSON>

Summary of changes:
<ONE PARAGRAPH>

Steps:
1. qa_load_project for <TARGET-REPO-PATH>.
2. If any AC needs the app running: qa_dev_start the appropriate server(s) and wait
   for healthcheck.
3. For each AC that lacks e2e coverage, qa_test_write or qa_test_extend a spec that
   asserts the specific behavior — not just that the code doesn't crash.
4. qa_test_run the new and changed-adjacent specs.
5. Set AC status from results: passed only if the asserting test actually proved the
   claim; failed if the test failed; blocked if it couldn't run; skipped only if you
   chose not to write a test (and explain why in note).
6. qa_report_render { projectId, runIds, title, summary, acceptanceCriteria }.
7. Return JSON: { reportPath, runIds, acceptanceCriteria (with final statuses),
   failureSummary, bugsFound? }.

Do NOT post a PR comment. The parent decides.
```

## Phase 5: Read the verdict honestly

When the subagent returns:
- If any AC came back `failed` or `blocked`, surface it plainly to the user **before** offering to post anything. Don't bury failures under a happy summary.
- If all passed, summarise in one sentence and ask whether to post the PR comment.
- If the subagent itself errored (e.g. couldn't load project, dev server didn't start), report the error verbatim and stop.

## Phase 6: Post — only with explicit approval

If the user confirms, call `qa_pr_post_report` with:
- `acceptanceCriteria`: final statuses from the subagent.
- `summary`: your one-paragraph synthesis.
- `runIds`, `prNumber`, `reportPath` (from subagent return).

Return the comment URL.

---

## What this skill does NOT do

- Doesn't push artifact branches. HTML report stays local in `.qa-bot/runs/`.
- Doesn't auto-post PR comments. User approval required.
- Doesn't fabricate AC. If a criterion is unclear, ask the user before guessing.
- Doesn't claim a test "validates" something unless its assertions actually exercise the claim.
