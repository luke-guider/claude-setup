# Package Install Gate — Design Spec

**Date:** 2026-05-15
**Status:** Design approved, pending implementation plan
**Scope:** Add a security gate that blocks unsafe package installs initiated by Claude Code or the user

## Problem

Recent npm supply-chain attacks (shai-hulud and others) have pushed malicious versions of trusted packages to public registries. Existing tooling — `npm audit`, lockfiles, code review — only catches problems *after* an install. By the time a postinstall script has run, the attack has already executed.

The user's current global rules already say "be cautious adding new dependencies" and "check for known vulnerabilities" — but those rules rely on Claude remembering and choosing to apply them. A skill is insufficient because it depends on agent compliance. The enforcement needs to live in the harness.

## Goal

Block package installs of:

1. **Newly published versions** (< 7 days old) that lack provenance proof — the most exploitable window
2. **Versions with known high/critical CVEs**
3. **Anything the gate cannot verify** (network failure, unknown registry) — default-deny on uncertainty

The gate must close common bypass routes (aliases, indirect shell invocations, postinstall scripts), provide a clear path to override when legitimately needed, and log every override for later audit.

## Non-goals

- Protecting against malicious code that runs at **runtime** (when a package is imported/required). Out of scope — only "don't import untrusted code" can address that.
- Protecting against arbitrary `curl | sh` shenanigans. No registry compromise involved.
- Replacing `npm audit` / OSV-scanner for lockfile-wide auditing. This gate covers install-time decisions; lockfile audits are a separate concern.

## Architecture

Two-layer enforcement:

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: Bash dispatcher (PreToolUse hook in settings.json)     │
│   - Regex on TOOL_INPUT for "install"-shaped commands           │
│   - Cheap, fast, no extra processes on miss                     │
│   - Fits existing pre-commit/pre-push hook pattern              │
└────────────────────────┬────────────────────────────────────────┘
                         │ on match → invoke
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ pre-install-checks.sh                                           │
│   - Parses ecosystem + package names + versions                 │
│   - Calls Python checker with structured args                   │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ package_gate.py                                                 │
│   - Resolves versions, queries OSV.dev + registry APIs          │
│   - Checks age, vulns, provenance                               │
│   - Honors allowlists, writes cache + bypass log                │
│   - Exits non-zero with structured message on block             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: PATH-prefixed binary wrappers (~/.claude/bin/)         │
│   - Wrappers named npm, pnpm, yarn, bun, pip, pip3, uv,         │
│     poetry, cargo, gem, go (brew not wrapped — see Limitations) │
│   - PATH=$HOME/.claude/bin:$PATH set via settings.json env      │
│   - Each wrapper: inspect args → gate if install → exec real    │
│   - Sets npm_config_ignore_scripts=true by default              │
│   - Catches aliases, scripts, functions, bash -c, eval          │
└─────────────────────────────────────────────────────────────────┘
```

### File layout (new files only)

```
claude-setup/
├── claude/
│   ├── settings.json              # MODIFIED: add PATH env, add install dispatch
│   ├── hooks/
│   │   ├── pre-install-checks.sh         # NEW: bash dispatcher
│   │   ├── package_gate.py               # NEW: Python checker
│   │   ├── package-gate-allowlist.json   # NEW: per-package allowlist
│   │   ├── vuln-allowlist.json           # NEW: per-CVE suppressions
│   │   └── ignore-scripts-allowlist.json # NEW: packages that may run scripts
│   └── bin/                              # NEW: PATH-prefixed wrappers
│       ├── _wrapper.sh                   # NEW: shared wrapper logic
│       ├── npm    → _wrapper.sh          # symlinks
│       ├── pnpm   → _wrapper.sh
│       ├── yarn   → _wrapper.sh
│       ├── bun    → _wrapper.sh
│       ├── pip    → _wrapper.sh
│       ├── pip3   → _wrapper.sh
│       ├── uv     → _wrapper.sh
│       ├── poetry → _wrapper.sh
│       ├── cargo  → _wrapper.sh
│       ├── gem    → _wrapper.sh
│       └── go     → _wrapper.sh
└── tests/                                # NEW: test directory (or extend existing)
    ├── test_package_gate.py
    ├── test_pre_install_checks.sh
    ├── test_wrappers.sh
    └── e2e_smoke.sh
```

## Check criteria

For each named package + resolved version, all three checks must pass:

### 1. Age ≥ 7 days since version publish

- If no version pinned → resolve to latest published version
- If version pinned → use that exact version
- "Publish time" = registry's timestamp for that specific version (not the package as a whole)
- **Bypass condition:** npm provenance attestation present → age check skipped (verified provenance means the publisher is who they claim to be)

### 2. No HIGH/CRITICAL vulnerabilities

- Single API call to OSV.dev (`POST https://api.osv.dev/v1/query` with `{package: {name, ecosystem}, version}`)
- Block when any returned vuln has CVSS ≥ 7.0 (preferred), OR — when CVSS is absent — its database-reported severity is `HIGH` or `CRITICAL`. OSV's `severity[]` array, the per-source severity label, and the GHSA `Severity` field are checked in that order.
- LOW/MEDIUM ignored to avoid alert fatigue
- Per-CVE suppressions honored if present in `vuln-allowlist.json` (with expiry)

### 3. Resolvable on registry

- If the registry returns 404 → block (typosquat protection)
- If the registry is unreachable → block (default-deny)

### Per-ecosystem endpoints

| Ecosystem | Resolve version | Age timestamp |
|---|---|---|
| npm/pnpm/yarn/bun | `GET registry.npmjs.org/<pkg>` → `.dist-tags.latest` | `.time.<version>` |
| PyPI (pip/uv/poetry) | `GET pypi.org/pypi/<pkg>/json` → `.info.version` | `.releases.<ver>[0].upload_time` |
| crates.io | `GET crates.io/api/v1/crates/<name>` → `.crate.max_version` | `.versions[].created_at` |
| RubyGems | `GET rubygems.org/api/v1/versions/<name>.json` | `.created_at` per version |
| Go | `GET proxy.golang.org/<module>/@latest` | `proxy.golang.org/<module>/@v/<v>.info` → `.Time` |

`brew` is not covered — see Limitations.

All vuln queries go through OSV.dev (one schema, all ecosystems).

## Command parsing

### Detected install commands

| Tool | Match | Notes |
|---|---|---|
| npm | `\bnpm\s+(i\|install\|add)\s+\S` | Requires at least one non-flag arg |
| pnpm | `\bpnpm\s+(add\|install\|i)\s+\S` | Requires non-flag arg |
| yarn | `\byarn\s+add\s+\S` | `yarn` alone = lockfile install, not matched |
| bun | `\bbun\s+(add\|install\|i)\s+\S` | Requires non-flag arg |
| pip / pip3 | `\b(pip\|pip3)\s+install\s+\S` | Must not be `-r`, `-e`, or `.` |
| uv | `\buv\s+(add\|pip\s+install)\s+\S` | |
| poetry | `\bpoetry\s+add\s+\S` | |
| cargo | `\bcargo\s+(add\|install)\s+\S` | |
| gem | `\bgem\s+install\s+\S` | |
| go | `\bgo\s+(get\|install)\s+\S+@\S` | Require `@version` form |

### Explicitly NOT intercepted (passes through)

- Lockfile installs: `npm install` (no args), `pnpm install`, `yarn` (no args), `bun install`
- Manifest installs: `pip install -r ...`, `pip install .`, `pip install -e ...`
- Build/test commands: `cargo build`, `cargo test`, `go build`
- Update commands: `npm update`, `cargo update`

### Package + version extraction

- Strip all `-*` flags from positional args
- Parse `name[@version]` (or `name==version` for pip)
- Handle npm scoped packages (`@scope/pkg@version`)
- If no version: resolve latest at check time

## Override mechanisms

Three layers, increasing friction:

### Per-package allowlist

`~/.claude/hooks/package-gate-allowlist.json`:

```json
{
  "npm": {
    "sharp": { "reason": "trusted, needs build scripts", "added": "2026-05-15" },
    "@my-org/internal-pkg": { "reason": "internal package", "added": "2026-05-15" }
  },
  "pip": {
    "requests": { "reason": "legitimate brand-new release", "added": "2026-05-15" }
  }
}
```

- Allowlisted package → skip age check (matches any version of that name; v1 does not parse SemVer ranges)
- Allowlisting is independent of `ignore-scripts-allowlist.json` — packages that need build scripts must be in both lists

### One-shot env var bypass

```bash
CLAUDE_PACKAGE_GATE_SKIP=1 CLAUDE_PACKAGE_GATE_REASON="patch for CVE-2026-9999" npm i foo@1.2.3
```

- Single command, doesn't persist
- Every bypass logged to `~/.claude/cache/package-gate/bypass.log`:
  ```
  2026-05-15T14:23:01Z  npm install foo@1.2.3  reason="patch for CVE-2026-9999"  user=lukebeach  cwd=/Users/lukebeach/REPOS/...
  ```

### Per-CVE suppression

`~/.claude/hooks/vuln-allowlist.json`:

```json
{
  "GHSA-abcd-1234": { "reason": "doesn't apply, we don't call .parse()", "expires": "2026-08-15" }
}
```

- Expiry mandatory — past expiry, suppression is ignored and the vuln blocks again

## Failure handling

| Failure | Behavior |
|---|---|
| OSV.dev unreachable | Block, suggest bypass with reason |
| Registry API unreachable | Block |
| Cache hit, fresh (< 24h) | Use cache |
| Cache hit, stale, network failure | Use stale cache + warn |
| Python script crash | Block, surface stack trace |
| Hook timeout (30s) | Block |
| Package not found on registry | Block (typosquat protection) |

**Principle: default-deny on uncertainty.** Fail-open means an attacker who can knock out OSV.dev for 30 seconds disables the gate.

## Postinstall script handling

The wrapper layer sets `npm_config_ignore_scripts=true` (and pnpm/yarn equivalents) by default in the exec'd environment. This blocks the single most common attack vector — postinstall scripts that exfiltrate or pivot.

Per-package opt-in via `ignore-scripts-allowlist.json`:

```json
{
  "npm": ["sharp", "bcrypt", "node-sass", "puppeteer"]
}
```

When installing a package in this list, the wrapper re-enables scripts just for that command.

## Caching

- Location: `~/.claude/cache/package-gate/`
- Key: `(ecosystem, package, version)`
- TTL: 24 hours
- Format: JSON per package — `{checked_at, age_days, vulns: [...], provenance: bool, decision}`
- Cache hit avoids API roundtrip; cache miss writes after check completes

## Block output format

```
🛑 Package install blocked by claude-setup gate

  Command: npm install left-pad@1.3.0
  Ecosystem: npm

  Findings for left-pad@1.3.0:
    ✗ AGE: published 2 days ago (threshold: 7 days)
    ✓ VULNS: no known high/critical CVEs
    ✗ PROVENANCE: no npm attestation

  To proceed:
    • Wait until 2026-05-20 (when version turns 7 days old)
    • Add to allowlist:  ~/.claude/hooks/package-gate-allowlist.json
    • One-shot bypass:   CLAUDE_PACKAGE_GATE_SKIP=1 npm install left-pad@1.3.0
                         (set CLAUDE_PACKAGE_GATE_REASON="..." to log why)

  Cached for 24h. Re-running won't re-hit registry.
```

Structured, machine-parseable, "to proceed" list in order of safety (wait safest, bypass loudest).

## Testing strategy

### Unit tests — `tests/test_package_gate.py`

Pytest with `unittest.mock`:
- Too-young version blocks
- Vulnerable version blocks
- Both fail → both shown
- Neither fails → pass
- Allowlisted package → skip age check
- npm provenance present → skip age check
- Version not found → block (typosquat)
- Malformed registry response → block
- Cache hit → no API call
- Cache stale + API down → use stale + warn

### Unit tests — `tests/test_pre_install_checks.sh`

BATS or plain shell:
- Each ecosystem's install patterns match correctly
- `npm install` (no args) does NOT match
- `pip install -r requirements.txt` does NOT match
- Scoped packages parsed correctly
- Flags stripped from positional args
- Version specifiers parsed per ecosystem

### Unit tests — `tests/test_wrappers.sh`

- Each wrapper identifies install vs non-install args correctly
- Each wrapper `exec`s the real binary (not itself — infinite loop guard)
- `npm_config_ignore_scripts` set when not in allowlist
- `npm_config_ignore_scripts` unset when in allowlist

### E2E smoke — `tests/e2e_smoke.sh`

Real network calls:
- Known-good: `react@18.0.0` → passes
- Known-bad: `lodash@4.17.20` (known CVE) → blocked on vulns
- Known-young: most-recently-published package on npm → blocked on age
- Network failure simulation → blocked

### CI

GitHub Actions workflow in claude-setup repo runs all four layers on every PR.

## Limitations (worth being explicit about)

1. **Runtime code execution is out of scope.** A package's runtime code can do anything when imported. The gate is a pre-install check; it cannot stop what runs at runtime.
2. **Allowlisted packages with build scripts can still do anything during install.** Opting a package into `ignore-scripts-allowlist.json` is a trust decision.
3. **brew is not covered at all.** Homebrew-core formulae are human-reviewed and there is no clean per-version publish timestamp to gate on. `brew install` passes through both Layer 1 and Layer 2 unmodified. May revisit if a credible threat emerges.
4. **Custom/private registries.** If a package isn't on the public registry, it blocks by default. Internal packages must be allowlisted.
5. **PATH-front wrappers only protect Claude's tool subshells.** The user's own terminal is unchanged by design — the user has judgment; the gate backstops Claude.

## Rollout

1. Implement wrappers + Python checker + dispatcher
2. Run in warn-only mode (log decisions, don't block) for one week to find false positives
3. Tune allowlists based on warn-mode logs
4. Flip to hard-block
5. Add CI workflow

## Open questions

None at design-approval time. Implementation plan will surface concrete questions as they arise.
