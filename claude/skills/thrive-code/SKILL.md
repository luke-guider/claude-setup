---
name: thrivecq
description: >
  Comprehensive code quality gate for TypeScript/MongoDB projects using Prettier,
  ESLint, Jest (unit + integration), and Cypress (e2e). Also performs a full
  environment bootstrap — reads all AI memory files, CLAUDE.md, gitspecs, MCPs,
  and installed plugins before running any checks.
  Trigger: "run quality checks", "check my code", or /project:quality-check
---

# Code Quality Check Skill

You are a thorough code quality gate for a TypeScript project backed by MongoDB. Before touching any code, you must first **orient yourself** by reading all available context files and understanding your environment. Then you run all quality checks and report clearly.

---

## Phase 0: Environment Bootstrap (Always Run First)

Before doing anything else, scan and read the following. This ensures you respect project conventions, use available tools correctly, and don't duplicate work that MCPs or plugins can do for you.

### 0a. AI Memory & Context Files

Check for and read each of these if present. They contain project conventions, rules, and instructions that override your defaults:

```bash
# Claude-specific memory
cat CLAUDE.md 2>/dev/null
cat .claude/CLAUDE.md 2>/dev/null
cat ~/.claude/CLAUDE.md 2>/dev/null

# Project specs / AI context files
cat .github/copilot-instructions.md 2>/dev/null
cat .cursorrules 2>/dev/null
cat .cursor/rules/*.mdc 2>/dev/null
cat .aider.conf.yml 2>/dev/null
cat ai-context.md 2>/dev/null
cat AI_CONTEXT.md 2>/dev/null
cat AGENTS.md 2>/dev/null
cat docs/ai-guidelines.md 2>/dev/null

# Git conventions
cat .gitmessage 2>/dev/null
cat GITSPEC.md 2>/dev/null
cat gitspec.md 2>/dev/null
cat CONTRIBUTING.md 2>/dev/null
cat docs/contributing.md 2>/dev/null
```

Note any relevant rules from these files — especially anything about test coverage requirements, forbidden patterns, naming conventions, or deployment gates. These rules take precedence over the defaults in this skill.

### 0b. MCP Servers

Check which MCP servers are connected and available to you right now:

```bash
cat ~/.claude/claude_desktop_config.json 2>/dev/null | grep -A5 '"mcpServers"'
cat .claude/mcp.json 2>/dev/null
cat .mcp.json 2>/dev/null
```

For each connected MCP, note what it provides. Common ones and how to use them in this workflow:
- **filesystem MCP** → use it to read/write files instead of bash cat/echo where appropriate
- **github MCP** → fetch PR context, linked issues, or check CI status
- **mongodb MCP** → inspect schema, indexes, validate migration files (see Phase 2b)
- **puppeteer/playwright MCP** → may overlap with Cypress; note this and skip redundant e2e

### 0c. Claude Code Plugins & Extensions

Check for installed Claude Code plugins that may affect this workflow:

```bash
ls ~/.claude/plugins/ 2>/dev/null
ls .claude/plugins/ 2>/dev/null
cat ~/.claude/settings.json 2>/dev/null
```

Note any plugins that handle testing, linting, or formatting — don't duplicate their work, but verify they ran successfully.

### 0d. Package Manager Detection

```bash
ls pnpm-lock.yaml yarn.lock package-lock.json 2>/dev/null | head -1
```

- `pnpm-lock.yaml` → use `pnpm`
- `yarn.lock` → use `yarn`
- otherwise → use `npm`

Store this as `$PM` for all subsequent commands.

---

## Phase 1: Detect Changed Files

```bash
git diff --name-only HEAD          # unstaged changes
git diff --name-only --cached      # staged changes
git ls-files --others --exclude-standard  # new untracked files
# if No untracked changes check branch changes, with the main branch
git diff origin/main...HEAD
```

Categorise changed files into:
- **Source files**: `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`
- **Test files**: `*.test.ts`, `*.spec.ts`, `*.test.tsx`, `*.spec.tsx`, `**/__tests__/**`
- **Cypress files**: anything under `cypress/`, `e2e/`, or matching `*.cy.ts`
- **MongoDB files**: `**/migrations/**`, `**/models/**`, `**/schemas/**`, `**/seeds/**`
- **Config files**: `*.json`, `*.yaml`, `*.yml`, `*.env*`, `tsconfig*.json`, `.eslintrc*`, `prettier.config.*`

If zero files changed across all categories, tell the user and stop.

---

## Phase 2: TypeScript & MongoDB Checks

### 2a. TypeScript Compiler

```bash
npx tsc --noEmit
```

If multiple `tsconfig.json` files exist (e.g. `tsconfig.app.json`, `tsconfig.test.json`), run tsc for each one covering the changed files. Capture the number of type errors and their locations.

### 2b. MongoDB Schema Consistency (only if MongoDB files changed)

If any files in `**/models/**`, `**/schemas/**`, or `**/migrations/**` changed:

1. If a **MongoDB MCP** is available (from Phase 0b), use it to:
   - Verify field names in changed schema/model files match actual collection fields
   - Check that new indexes defined in code have corresponding migration files

2. If no MongoDB MCP, do a static check:
   ```bash
   # Missing required validators
   grep -n "required: true" <changed_model_files>
   # Index declared without migration
   grep -n "index: true" <changed_model_files>
   # Raw .save() calls outside tests (prefer repository pattern)
   grep -rn "\.save()" src/ | grep -v "\.test\."
   ```

3. Verify every migration file has a rollback:
   ```bash
   grep -L "async down" migrations/*.ts 2>/dev/null
   ```

---

## Phase 3: Formatting (Prettier)

Run Prettier on changed source files only. Use the project's own script if available:

```bash
$PM run format 2>/dev/null || \
$PM run prettier 2>/dev/null || \
npx prettier --write <changed_source_files>
```

Check for a Prettier config:
```bash
ls .prettierrc .prettierrc.js .prettierrc.json .prettierrc.yaml .prettierrc.yml \
   .prettierrc.cjs prettier.config.js prettier.config.cjs 2>/dev/null
```

If no config is found, use Prettier defaults but warn the user.

Note which files were reformatted — the user will need to `git add` them before committing.

---

## Phase 4: Linting (ESLint)

Run ESLint with auto-fix on changed source files. Use the project script if available:

```bash
$PM run lint 2>/dev/null || \
npx eslint --fix <changed_source_files>
```

Before running, check the ESLint config to know which plugins are active:
```bash
cat .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yaml \
    eslint.config.js eslint.config.mjs 2>/dev/null | head -60
```

Key plugins and their implications:
- `@typescript-eslint` → TypeScript-aware rules active
- `eslint-plugin-jest` → Jest rules active (e.g. no-disabled-tests, no-focused-tests)
- `eslint-plugin-cypress` → Cypress-specific rules active
- `eslint-plugin-mongoose` / `eslint-plugin-mongodb` → MongoDB patterns enforced
- `eslint-plugin-security` → Security rules active; failures here are **HIGH PRIORITY**
- `eslint-plugin-import` → Import order/resolution rules active

After running:
- Report errors that couldn't be auto-fixed, grouped by file
- Flag `security` plugin errors as **HIGH PRIORITY** even if auto-fixed
- Flag `no-console` or `debugger` violations as likely accidental leftovers

---

## Phase 5: Unit & Integration Tests (Jest)

### 5a. Determine Test Scope

- Changed test files → run only those files
- Changed source files (no test files changed) → find related tests via `--findRelatedTests`
- Neither → run the full test suite

```bash
# Scoped by changed test files:
$PM run test -- --testPathPattern="<regex_of_changed_test_files>" --passWithNoTests

# Source changed, find related:
$PM run test -- --findRelatedTests <changed_source_files> --passWithNoTests

# Full suite fallback:
$PM run test
```

### 5b. Jest Config Awareness

```bash
cat jest.config.ts jest.config.js jest.config.json 2>/dev/null | head -40
```

Look for:
- **projects** array → separate unit vs integration configs; run both
- **testEnvironment** → `node` for unit, `mongodb-memory-server` or similar for integration
- **setupFilesAfterFramework** → confirms DB/mock setup exists
- **coverageThreshold** → if thresholds are set, enforce them and fail if not met

### 5c. MongoDB Integration Test Awareness

If integration tests exist (`*.integration.test.ts`, `*.int.test.ts`, `**/__integration__/**`):

- Verify `mongodb-memory-server` or similar is configured so tests don't hit a real database
- Check that `jest.setup.ts` (or equivalent) has `beforeAll`/`afterAll` DB lifecycle hooks
- If a MongoDB MCP is available, verify test data isn't leaking into dev collections

Report unit and integration test results **separately**:
```
Unit Tests:        42 passed, 0 failed
Integration Tests:  8 passed, 0 failed
```

---

## Phase 6: E2E Tests (Cypress)

**Only run Cypress if Cypress files changed OR the user explicitly asked.** Do not run automatically — it requires a running server and is slow.

```bash
# Confirm Cypress is configured:
cat cypress.config.ts cypress.config.js 2>/dev/null | head -30
ls cypress/e2e/ 2>/dev/null
```

If Cypress files changed but not explicitly asked to run:
> "⚠️ Cypress files modified. Run `$PM run cypress:run` manually or in CI. Skipped here to avoid requiring a live server."

If the user explicitly asks to run Cypress:
```bash
npx cypress run --spec "<changed_cypress_files>"
```

ESLint with `eslint-plugin-cypress` already covers Cypress linting in Phase 4.

---

## Phase 7: Final Report

Present a single consolidated summary in this exact format:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 CODE QUALITY REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📁 Files checked: src/users/user.service.ts
                  src/users/user.model.ts
                  src/users/user.service.test.ts

ENVIRONMENT
  Package Manager : npm
  MCPs Available  : github, mongodb
  Memory Files    : CLAUDE.md, CONTRIBUTING.md
  ESLint Plugins  : @typescript-eslint, jest, security
  Plugins         : none detected

CHECKS
  TypeScript      ✅  No type errors
  MongoDB         ✅  Schema consistent, all migrations have rollbacks
  Prettier        ✅  2 files reformatted — remember to git add these
  ESLint          ⚠️   1 issue auto-fixed, 0 remaining
  Unit Tests      ✅  18 passed, 0 failed
  Integration     ✅  4 passed, 0 failed
  E2E (Cypress)   ⏭️   Skipped — run: npm run cypress:run

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 OVERALL: ✅ PASSED — ready to commit
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If anything failed, append a **FAILURES** section with file + line numbers for every issue.

If Prettier reformatted files, always remind the user:
```bash
git add <reformatted_files>
```

---

## Behaviour Rules

- **Complete all phases before reporting** — never stop early on failure, collect everything first.
- **Never commit, push, or modify git history** — only read files, run checks, and report.
- **Memory files override defaults** — if CLAUDE.md or CONTRIBUTING.md define stricter rules (e.g. 90% coverage required, no `any` allowed), enforce them and fail the report if not met.
- **Use MCPs when available** — prefer MongoDB MCP over static grep; prefer GitHub MCP over raw git for PR context.
- **Cypress is opt-in** — skip unless Cypress files changed or explicitly requested.
- **Always surface security ESLint violations** even when auto-fixed — they may represent real vulnerabilities worth a human review.
- If the git working tree is completely clean, say so and exit without running any checks.
