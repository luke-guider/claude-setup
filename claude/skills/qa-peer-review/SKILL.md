---
name: qa-peer-review
description: >
  Use to validate someone else's branch or PR end-to-end with qa-bot. Reads the PR
  description, linked Jira/GitHub tickets, and diff to extract claimed behavior. Checks
  out the branch, dispatches a subagent to write+run e2e tests that ASSERT the claims
  (not just exercise paths), renders an HTML report, and (with approval) posts a
  structured PR comment. Bias: treat the PR description as a hypothesis to verify, not
  as fact.
  Trigger: "qa this PR", "review PR <num>", "peer-review", "test someone else's
  branch", or /qa-peer-review
---

# qa-peer-review

You're validating work someone else did. The PR description is a *claim*, not a fact. Your job is to verify the claim — not to be polite, and not to merely exercise the code paths.

## Prerequisites — verify first, stop if any fail

- Target repo has `qa-bot.config.ts` at its root.
- `gh auth status` shows access to the PR's repo.
- 21 `qa_*` MCP tools available.
- Working tree in the target repo is clean — never checkout someone else's branch over dirty local work.

If any prerequisite fails, report exactly what's missing and stop.

---

## Phase 1: Identify what you're QAing

If the user gave you a PR number, use it. Otherwise ask — don't guess.

```bash
gh pr view <num> --json title,body,headRefName,baseRefName,author,labels,commits
```

Capture: branch name, base branch, author, title, body.

## Phase 2: Read the claim surface

Most important phase. AC come from what the *author claims*, not from what you imagine the feature should do.

1. **PR description** — what does the body explicitly claim? List each claim verbatim.
2. **Linked tickets** —
   - Jira (from PR body or branch name prefix): Atlassian MCP `getJiraIssue`. Capture the AC section verbatim.
   - GitHub issues: `gh issue view <num>` for each linked issue.
3. **Test plan** — if the PR has a Test Plan / QA Steps section, extract every checkbox as a separate AC.

If the PR has no description and no linked ticket, stop and ask the user how to derive AC. Don't fabricate.

## Phase 3: Read the diff vs. the claims

`gh pr diff <num>` (or `gh pr diff <num> --name-only` first, then read interesting files). Skim with these questions in mind:

- Does the diff match the description? Flag mismatches.
- Are there changes the description doesn't mention? Flag them — they need AC too.
- Are there obvious bugs the AC won't catch (off-by-one, missing null check, wrong assertion, console.log left in, security smell)? Note these for the bugs-found section of the PR comment.

## Phase 4: Derive acceptance criteria

Produce an `acceptanceCriteria` array combining:
- One entry per *verbatim claim* in PR body or linked ticket.
- One entry per *test plan checkbox*.
- One entry per *significant change in the diff the description didn't address* — mark these with a `note` explaining the gap.

Default every status to `blocked`. You haven't tested anything yet.

## Phase 5: Checkout the branch safely

In the target repo:

```bash
git status  # must be clean
git fetch origin <headRefName>
git checkout <headRefName>
```

If `git status` shows uncommitted changes, stop and tell the user — don't trash their work.

## Phase 5.5: Verify e2e framework readiness — NEVER scaffold someone else's PR

Check what the PR's branch can run, using the same detection as qa-self-review's Phase 1.5 (Playwright / Flutter / Maestro).

**Hard rule: do not scaffold a missing framework in someone else's PR.** It's outside the review's scope and pollutes their branch with infrastructure changes unrelated to the PR's intent.

Branch on what's available:

- **All required drivers ready** → proceed to the standard subagent dispatch in Phase 6.

- **Some/all drivers missing, but the dev server is configured** (`qa-bot.config.ts` has a `devServer` entry, or you can start a dev server some other way) → use `qa_scratch_run` to write **asserting** scratch tests:
  - Start the dev server (`qa_dev_start` if in a project, or however the PR's setup requires).
  - For each UI-related AC, write a Playwright spec asserting the specific behavior. Pass the full spec source to `qa_scratch_run` along with the dev server's baseURL.
  - Each `qa_scratch_run` returns a `runId` you can pass to `qa_report_render` / `qa_pr_post_report` exactly like `qa_test_run` results.
  - In the final PR comment summary, include this caveat (smaller than the old browser-observation caveat — scratch tests ARE asserting tests, just not persisted in the target repo):
    > Verified via scratch e2e tests (qa_scratch_run); the PR's repo has no permanent
    > Playwright setup. Recommend the project adopt e2e tooling so this coverage
    > persists in the repo.
  - **Do NOT** fall back to `qa_browse_*` snapshot observation here — `qa_scratch_run` provides asserting confidence and the snapshot path is now legacy.

- **No `qa-bot.config.ts` OR no dev server config** → can't even run the app. Drop to **diff-only review**:
  - Skip all e2e steps.
  - Read every changed file and reason about correctness from the code alone.
  - Status every AC `blocked` with note `not programmatically verifiable — repo has no QA infrastructure`.
  - Still populate the bugs-found section from diff reading; that's still useful signal.
  - In the PR comment, prominently flag the missing infrastructure as the top recommendation.

## Phase 6: Dispatch the QA subagent

Adjust the brief based on the path chosen in Phase 5.5:
- **All drivers ready** → use the standard brief below (asserting tests).
- **Scratch tests via `qa_scratch_run`** → swap steps 3 and 5: the subagent authors a Playwright spec per AC and passes the source to `qa_scratch_run` (with the dev server's baseURL) instead of `qa_test_write` + `qa_test_run`. Each call returns a `runId` that feeds `qa_report_render` / `qa_pr_post_report` the same way. Do NOT use `qa_browse_*` here — assertions only.
- **Diff-only review** → skip the subagent entirely; do the analysis inline in this session.

Standard brief (all drivers ready):

```
You are a QA subagent. Validate PR #<NUM> on branch <BRANCH> in <TARGET-REPO-PATH>.

Author claims (treat as hypotheses — your tests must DISPROVE or CONFIRM each):

<AC LIST as JSON>

Diff summary:
<ONE PARAGRAPH>

Steps:
1. qa_load_project for <TARGET-REPO-PATH>.
2. qa_dev_start servers as needed.
3. For each AC, qa_test_write (or qa_test_extend) a spec whose assertions exercise the
   SPECIFIC claim. A test that runs without crashing does not prove a claim. A test
   that asserts the user-visible outcome (text appears, status code, DB state, screen
   transition) does prove it.
4. If a claim is too vague to test, set status `blocked` and explain in the note —
   don't invent assertions.
5. qa_test_run the new specs.
6. Set AC status from results.
7. Note any BUGS found outside the AC list: console errors, broken neighbouring flows,
   regressions, suspicious code paths you executed.
8. qa_report_render and return JSON:
   { reportPath, runIds, acceptanceCriteria (with final statuses), bugsFound: [...] }.

Do NOT post a PR comment.
```

## Phase 7: Synthesise an honest verdict

When the subagent returns, summarise to the user:
- **Claim-vs-reality table** — which claims held, which didn't, which couldn't be tested.
- **Bugs found outside AC** — list them.
- **Recommended verdict** — approve / request changes / block. Justify in one sentence each.

Then ask whether to post the PR comment.

## Phase 8: Post — only with explicit approval

`qa_pr_post_report` with:
- `summary`: your synthesis (claim-vs-reality + bugs-found section in markdown).
- `acceptanceCriteria`: final statuses.
- `runIds`, `prNumber`, `reportPath`.

Return the comment URL.

---

## What this skill does NOT do

- Doesn't run `gh pr review --approve` / `--request-changes`. It posts a *comment*; the human reviewer decides what to do with it.
- Doesn't trust the PR description. Every claim is a hypothesis until a test proves it.
- Doesn't fabricate AC for undocumented PRs. Ask the user.
- Doesn't modify the PR branch. Strictly read-only on someone else's work.
- Doesn't soften failures to be polite. Honest verdict, every time.
