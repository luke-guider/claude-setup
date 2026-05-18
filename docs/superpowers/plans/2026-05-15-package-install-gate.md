# Package Install Security Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a two-layer security gate that blocks unsafe package installs initiated by Claude Code or the user, defaulting deny on uncertainty.

**Architecture:** Layer 1 is a bash `PreToolUse` hook that detects install commands via regex on `TOOL_INPUT`. Layer 2 is a PATH-prefixed directory of binary wrappers (`npm`, `pip`, etc.) that intercepts indirect invocations the regex can't see (aliases, scripts, `bash -c`, functions). Both layers call a Python checker that queries OSV.dev for vulnerabilities and each ecosystem's registry for version-age data, returning a structured decision.

**Tech Stack:** Python 3 stdlib only (urllib, json, argparse, unittest, mock) — no pip install required. Bash 4+. JSON config files. APIs: OSV.dev, registry.npmjs.org, pypi.org, crates.io, rubygems.org, proxy.golang.org.

**Spec reference:** `docs/superpowers/specs/2026-05-15-package-install-gate-design.md`

---

## File Structure

```
~/claude-setup/
├── claude/
│   ├── settings.json                     # MODIFY (Task 12): add PATH env, install dispatch
│   ├── hooks/
│   │   ├── pre-install-checks.sh         # NEW (Task 10): bash dispatcher
│   │   ├── package_gate.py               # NEW (Tasks 1-9): Python checker
│   │   ├── package-gate-allowlist.json   # NEW (Task 5): per-package allowlist
│   │   ├── vuln-allowlist.json           # NEW (Task 6): per-CVE suppressions
│   │   └── ignore-scripts-allowlist.json # NEW (Task 11): packages allowed to run scripts
│   └── bin/                              # NEW (Task 11): PATH-prefixed wrappers
│       ├── _wrapper.sh                   # shared wrapper logic
│       └── (11 symlinks → _wrapper.sh)
└── tests/
    ├── __init__.py                       # NEW (Task 1): makes tests/ a package
    ├── test_package_gate.py              # NEW (Tasks 1-9, 13-17): Python unit tests
    ├── test_pre_install_checks.sh        # NEW (Task 10): dispatcher tests
    ├── test_wrappers.sh                  # NEW (Task 11): wrapper tests
    └── e2e_smoke.sh                      # NEW (Task 13): real-API smoke tests
```

**File responsibilities:**
- `package_gate.py` — pure logic + HTTP calls; takes ecosystem + package + version(s), returns JSON decision, exits non-zero on block
- `pre-install-checks.sh` — parses `TOOL_INPUT`, extracts ecosystem + packages, dispatches to Python; thin
- `_wrapper.sh` — runs as 11 different binaries via `$0` dispatch; intercepts install patterns, sets ignore-scripts defaults, `exec`s the real binary
- Three allowlist JSON files — hand-edited or programmatic appends, starts empty

---

## Task 1: Test infrastructure + first failing age-check test

**Files:**
- Create: `tests/__init__.py` (empty)
- Create: `tests/test_package_gate.py`
- Create: `claude/hooks/package_gate.py` (empty stub)

- [ ] **Step 1: Create empty test package marker**

```bash
mkdir -p ~/claude-setup/tests
touch ~/claude-setup/tests/__init__.py
```

- [ ] **Step 2: Create empty checker stub**

```bash
touch ~/claude-setup/claude/hooks/package_gate.py
```

- [ ] **Step 3: Write the first failing test**

Path: `~/claude-setup/tests/test_package_gate.py`

```python
import json
import os
import sys
import unittest
from unittest.mock import patch, MagicMock
from datetime import datetime, timezone, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "claude", "hooks"))
import package_gate


def npm_registry_response(version, publish_iso):
    return {
        "dist-tags": {"latest": version},
        "time": {version: publish_iso, "created": publish_iso, "modified": publish_iso},
        "versions": {version: {"name": "left-pad", "version": version}},
    }


class TestAgeCheck(unittest.TestCase):
    def test_npm_version_younger_than_seven_days_blocks(self):
        two_days_ago = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        fake_response = npm_registry_response("1.3.0", two_days_ago)

        with patch.object(package_gate, "_http_get_json", return_value=fake_response):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.3.0"
            )

        self.assertFalse(decision["pass"])
        self.assertIn("AGE", [f["check"] for f in decision["failures"]])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Run the test to verify it fails**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: FAIL — `AttributeError: module 'package_gate' has no attribute 'check_package'` (or similar). The test cannot even import the function yet.

- [ ] **Step 5: Commit**

```bash
cd ~/claude-setup
git add tests/__init__.py tests/test_package_gate.py claude/hooks/package_gate.py
git commit -m "test(package-gate): scaffold tests + checker stub"
```

---

## Task 2: Implement age check for npm

**Files:**
- Modify: `claude/hooks/package_gate.py`

- [ ] **Step 1: Implement the minimum to make Task 1's test pass**

Path: `~/claude-setup/claude/hooks/package_gate.py`

```python
"""Package install security gate. Run as a CLI; importable for tests."""

import argparse
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone, timedelta

AGE_THRESHOLD_DAYS = 7
HTTP_TIMEOUT = 10


def _http_get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "claude-setup-package-gate/1.0"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _npm_version_publish_time(name, version):
    data = _http_get_json(f"https://registry.npmjs.org/{name}")
    times = data.get("time", {})
    if version not in times:
        return None
    return datetime.fromisoformat(times[version].replace("Z", "+00:00"))


def _age_days(publish_dt):
    return (datetime.now(timezone.utc) - publish_dt).days


def check_package(ecosystem, name, version):
    failures = []

    if ecosystem == "npm":
        publish_dt = _npm_version_publish_time(name, version)
        if publish_dt is None:
            failures.append({"check": "RESOLVE", "detail": f"version {version} not found"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days)",
                "publish_dt": publish_dt.isoformat(),
            })

    return {
        "pass": not failures,
        "failures": failures,
        "name": name,
        "version": version,
    }
```

- [ ] **Step 2: Run the test to verify it passes**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestAgeCheck -v
```

Expected: PASS.

- [ ] **Step 3: Add a positive-case test (≥7 days old passes age check)**

Append to `tests/test_package_gate.py` inside `TestAgeCheck`:

```python
    def test_npm_version_older_than_seven_days_passes_age(self):
        ten_days_ago = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        fake_response = npm_registry_response("1.3.0", ten_days_ago)

        with patch.object(package_gate, "_http_get_json", return_value=fake_response):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.3.0"
            )

        self.assertTrue(decision["pass"])
        self.assertEqual(decision["failures"], [])
```

- [ ] **Step 4: Add test for version-not-found (typosquat protection)**

Append to `tests/test_package_gate.py`:

```python
    def test_npm_version_not_in_registry_blocks(self):
        fake_response = npm_registry_response("1.0.0", datetime.now(timezone.utc).isoformat())

        with patch.object(package_gate, "_http_get_json", return_value=fake_response):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="99.99.99"
            )

        self.assertFalse(decision["pass"])
        self.assertIn("RESOLVE", [f["check"] for f in decision["failures"]])
```

- [ ] **Step 5: Run all age-check tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestAgeCheck -v
```

Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add tests/test_package_gate.py claude/hooks/package_gate.py
git commit -m "feat(package-gate): npm version age check via registry"
```

---

## Task 3: OSV.dev vulnerability check

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing test for HIGH severity blocking**

Append to `tests/test_package_gate.py`:

```python
class TestVulnCheck(unittest.TestCase):
    def _osv_response(self, severities):
        return {
            "vulns": [
                {
                    "id": f"GHSA-test-{i:04d}",
                    "severity": [{"type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}],
                    "database_specific": {"severity": sev},
                }
                for i, sev in enumerate(severities)
            ]
        }

    def test_high_severity_vuln_blocks(self):
        old_iso = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
        npm_resp = npm_registry_response("1.0.0", old_iso)
        osv_resp = self._osv_response(["HIGH"])

        def fake_get(url, *args, **kwargs):
            if "osv.dev" in url:
                return osv_resp
            return npm_resp

        def fake_post(url, body):
            return osv_resp

        with patch.object(package_gate, "_http_get_json", side_effect=fake_get), \
             patch.object(package_gate, "_http_post_json", side_effect=fake_post):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertFalse(decision["pass"])
        self.assertIn("VULNS", [f["check"] for f in decision["failures"]])

    def test_low_severity_vuln_passes(self):
        old_iso = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
        npm_resp = npm_registry_response("1.0.0", old_iso)
        osv_resp = self._osv_response(["LOW", "MEDIUM"])

        with patch.object(package_gate, "_http_get_json", return_value=npm_resp), \
             patch.object(package_gate, "_http_post_json", return_value=osv_resp):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertTrue(decision["pass"])
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestVulnCheck -v
```

Expected: FAIL — `_http_post_json` does not exist.

- [ ] **Step 3: Implement OSV check**

In `claude/hooks/package_gate.py`, add after `_http_get_json`:

```python
def _http_post_json(url, body):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "User-Agent": "claude-setup-package-gate/1.0",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


OSV_ECOSYSTEM = {
    "npm": "npm",
    "pip": "PyPI",
    "cargo": "crates.io",
    "gem": "RubyGems",
    "go": "Go",
}


def _osv_severity(vuln):
    db = (vuln.get("database_specific") or {}).get("severity")
    if db:
        return db.upper()
    for sev in vuln.get("severity", []):
        if sev.get("type") == "CVSS_V3":
            score_str = sev.get("score", "")
            try:
                num = float(score_str.split("/")[-1]) if score_str.replace(".", "", 1).isdigit() else None
            except (ValueError, IndexError):
                num = None
            if num is not None and num >= 7.0:
                return "HIGH"
    return "UNKNOWN"


def _osv_query(ecosystem, name, version):
    osv_eco = OSV_ECOSYSTEM.get(ecosystem)
    if osv_eco is None:
        return []
    body = {"package": {"name": name, "ecosystem": osv_eco}, "version": version}
    resp = _http_post_json("https://api.osv.dev/v1/query", body)
    return resp.get("vulns", []) or []
```

Update `check_package` to call OSV after the age check (replace the function):

```python
def check_package(ecosystem, name, version):
    failures = []

    if ecosystem == "npm":
        publish_dt = _npm_version_publish_time(name, version)
        if publish_dt is None:
            failures.append({"check": "RESOLVE", "detail": f"version {version} not found"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days)",
                "publish_dt": publish_dt.isoformat(),
            })

    vulns = _osv_query(ecosystem, name, version)
    blocking = [v for v in vulns if _osv_severity(v) in ("HIGH", "CRITICAL")]
    if blocking:
        failures.append({
            "check": "VULNS",
            "detail": f"{len(blocking)} high/critical vulnerability(s)",
            "ids": [v["id"] for v in blocking],
        })

    return {
        "pass": not failures,
        "failures": failures,
        "name": name,
        "version": version,
    }
```

- [ ] **Step 4: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: all tests pass (age + vulns).

- [ ] **Step 5: Commit**

```bash
cd ~/claude-setup
git add tests/test_package_gate.py claude/hooks/package_gate.py
git commit -m "feat(package-gate): OSV.dev vulnerability check, block on HIGH/CRITICAL"
```

---

## Task 4: npm provenance short-circuits age check

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_package_gate.py`:

```python
class TestProvenance(unittest.TestCase):
    def test_npm_provenance_skips_age_check(self):
        two_days_ago = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        npm_resp = npm_registry_response("1.0.0", two_days_ago)
        npm_resp["versions"]["1.0.0"]["dist"] = {
            "attestations": {"url": "https://registry.npmjs.org/-/npm/v1/attestations/left-pad@1.0.0"}
        }

        with patch.object(package_gate, "_http_get_json", return_value=npm_resp), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertTrue(decision["pass"])

    def test_npm_no_provenance_two_days_old_still_blocks(self):
        two_days_ago = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        npm_resp = npm_registry_response("1.0.0", two_days_ago)

        with patch.object(package_gate, "_http_get_json", return_value=npm_resp), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertFalse(decision["pass"])
```

- [ ] **Step 2: Run to verify first test fails**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestProvenance -v
```

Expected: `test_npm_provenance_skips_age_check` FAILS, second test PASSES.

- [ ] **Step 3: Implement provenance check**

In `claude/hooks/package_gate.py`, add helper:

```python
def _npm_has_provenance(registry_data, version):
    versions = registry_data.get("versions", {})
    dist = (versions.get(version) or {}).get("dist", {})
    attestations = dist.get("attestations")
    return bool(attestations)
```

Modify `check_package` — refactor to fetch npm data once and reuse:

```python
def check_package(ecosystem, name, version):
    failures = []
    has_provenance = False

    if ecosystem == "npm":
        registry_data = _http_get_json(f"https://registry.npmjs.org/{name}")
        times = registry_data.get("time", {})
        if version not in times:
            failures.append({"check": "RESOLVE", "detail": f"version {version} not found"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        publish_dt = datetime.fromisoformat(times[version].replace("Z", "+00:00"))
        has_provenance = _npm_has_provenance(registry_data, version)
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS and not has_provenance:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days, no provenance)",
                "publish_dt": publish_dt.isoformat(),
            })

    vulns = _osv_query(ecosystem, name, version)
    blocking = [v for v in vulns if _osv_severity(v) in ("HIGH", "CRITICAL")]
    if blocking:
        failures.append({
            "check": "VULNS",
            "detail": f"{len(blocking)} high/critical vulnerability(s)",
            "ids": [v["id"] for v in blocking],
        })

    return {
        "pass": not failures,
        "failures": failures,
        "name": name,
        "version": version,
        "provenance": has_provenance,
    }
```

The helper `_npm_version_publish_time` is no longer used — delete it.

- [ ] **Step 4: Update Task 1+2 tests that called `_npm_version_publish_time`**

The Task 1 test patched `_http_get_json` already, so it should still work. Run all tests:

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/claude-setup
git add tests/test_package_gate.py claude/hooks/package_gate.py
git commit -m "feat(package-gate): npm provenance attestation short-circuits age check"
```

---

## Task 5: Per-package allowlist

**Files:**
- Create: `claude/hooks/package-gate-allowlist.json`
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Create the allowlist file with documentation**

Path: `~/claude-setup/claude/hooks/package-gate-allowlist.json`

```json
{
  "_doc": "Packages allowlisted to skip the age check. Match by name only (any version).",
  "_schema": {
    "<ecosystem>": {
      "<package-name>": {
        "reason": "why allowlisted",
        "added": "YYYY-MM-DD"
      }
    }
  },
  "npm": {},
  "pip": {},
  "cargo": {},
  "gem": {},
  "go": {}
}
```

- [ ] **Step 2: Write failing test**

Append to `tests/test_package_gate.py`:

```python
class TestAllowlist(unittest.TestCase):
    def test_allowlisted_package_skips_age_check(self):
        two_days_ago = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        npm_resp = npm_registry_response("1.0.0", two_days_ago)
        allowlist = {"npm": {"left-pad": {"reason": "test", "added": "2026-05-15"}}}

        with patch.object(package_gate, "_http_get_json", return_value=npm_resp), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value=allowlist):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertTrue(decision["pass"])

    def test_non_allowlisted_package_blocks_on_age(self):
        two_days_ago = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        npm_resp = npm_registry_response("1.0.0", two_days_ago)
        allowlist = {"npm": {}}

        with patch.object(package_gate, "_http_get_json", return_value=npm_resp), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value=allowlist):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertFalse(decision["pass"])
```

- [ ] **Step 3: Implement allowlist loading + check**

In `claude/hooks/package_gate.py`, add near the top:

```python
from pathlib import Path

ALLOWLIST_PATH = Path.home() / ".claude" / "hooks" / "package-gate-allowlist.json"


def _load_allowlist():
    if not ALLOWLIST_PATH.exists():
        return {}
    try:
        return json.loads(ALLOWLIST_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def _is_allowlisted(ecosystem, name, allowlist):
    eco = allowlist.get(ecosystem, {})
    if not isinstance(eco, dict):
        return False
    return name in eco
```

Modify `check_package` — pull the allowlist check up front:

```python
def check_package(ecosystem, name, version):
    failures = []
    has_provenance = False
    allowlist = _load_allowlist()
    allowlisted = _is_allowlisted(ecosystem, name, allowlist)

    if ecosystem == "npm":
        registry_data = _http_get_json(f"https://registry.npmjs.org/{name}")
        times = registry_data.get("time", {})
        if version not in times:
            failures.append({"check": "RESOLVE", "detail": f"version {version} not found"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        publish_dt = datetime.fromisoformat(times[version].replace("Z", "+00:00"))
        has_provenance = _npm_has_provenance(registry_data, version)
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS and not has_provenance and not allowlisted:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days, no provenance, not allowlisted)",
                "publish_dt": publish_dt.isoformat(),
            })

    vulns = _osv_query(ecosystem, name, version)
    blocking = [v for v in vulns if _osv_severity(v) in ("HIGH", "CRITICAL")]
    if blocking:
        failures.append({
            "check": "VULNS",
            "detail": f"{len(blocking)} high/critical vulnerability(s)",
            "ids": [v["id"] for v in blocking],
        })

    return {
        "pass": not failures,
        "failures": failures,
        "name": name,
        "version": version,
        "provenance": has_provenance,
        "allowlisted": allowlisted,
    }
```

Note: vuln checks are NOT skipped by the allowlist — a package may be trusted for "new release" but a CVE found later must still block. The allowlist only suppresses the age check.

- [ ] **Step 4: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package-gate-allowlist.json claude/hooks/package_gate.py tests/test_package_gate.py
git commit -m "feat(package-gate): per-package allowlist skips age check"
```

---

## Task 6: Per-CVE vulnerability allowlist with expiry

**Files:**
- Create: `claude/hooks/vuln-allowlist.json`
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Create the vuln-allowlist file**

Path: `~/claude-setup/claude/hooks/vuln-allowlist.json`

```json
{
  "_doc": "Suppress specific OSV/GHSA IDs from blocking. expires is mandatory (YYYY-MM-DD).",
  "_schema": {
    "<vuln-id>": {
      "reason": "why suppressed",
      "expires": "YYYY-MM-DD"
    }
  }
}
```

- [ ] **Step 2: Write failing tests**

Append to `tests/test_package_gate.py`:

```python
class TestVulnAllowlist(unittest.TestCase):
    def _ten_days_old_npm(self):
        old = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
        return npm_registry_response("1.0.0", old)

    def _high_vuln_osv(self, vuln_id):
        return {
            "vulns": [{
                "id": vuln_id,
                "severity": [],
                "database_specific": {"severity": "HIGH"},
            }]
        }

    def test_suppressed_unexpired_vuln_passes(self):
        future = (datetime.now(timezone.utc) + timedelta(days=30)).date().isoformat()
        suppressions = {"GHSA-test-0001": {"reason": "doesn't apply", "expires": future}}

        with patch.object(package_gate, "_http_get_json", return_value=self._ten_days_old_npm()), \
             patch.object(package_gate, "_http_post_json", return_value=self._high_vuln_osv("GHSA-test-0001")), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value=suppressions):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertTrue(decision["pass"])

    def test_suppressed_expired_vuln_blocks(self):
        past = (datetime.now(timezone.utc) - timedelta(days=1)).date().isoformat()
        suppressions = {"GHSA-test-0001": {"reason": "old", "expires": past}}

        with patch.object(package_gate, "_http_get_json", return_value=self._ten_days_old_npm()), \
             patch.object(package_gate, "_http_post_json", return_value=self._high_vuln_osv("GHSA-test-0001")), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value=suppressions):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertFalse(decision["pass"])
```

- [ ] **Step 3: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestVulnAllowlist -v
```

Expected: FAIL — `_load_vuln_suppressions` does not exist.

- [ ] **Step 4: Implement vuln suppression**

In `claude/hooks/package_gate.py`, add:

```python
from datetime import date

VULN_ALLOWLIST_PATH = Path.home() / ".claude" / "hooks" / "vuln-allowlist.json"


def _load_vuln_suppressions():
    if not VULN_ALLOWLIST_PATH.exists():
        return {}
    try:
        return json.loads(VULN_ALLOWLIST_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def _is_vuln_suppressed(vuln_id, suppressions):
    entry = suppressions.get(vuln_id)
    if not isinstance(entry, dict):
        return False
    expires = entry.get("expires")
    if not expires:
        return False
    try:
        expiry_date = date.fromisoformat(expires)
    except ValueError:
        return False
    return date.today() <= expiry_date
```

Modify the vuln-checking block in `check_package`:

```python
    vulns = _osv_query(ecosystem, name, version)
    suppressions = _load_vuln_suppressions()
    blocking = [
        v for v in vulns
        if _osv_severity(v) in ("HIGH", "CRITICAL")
        and not _is_vuln_suppressed(v["id"], suppressions)
    ]
    if blocking:
        failures.append({
            "check": "VULNS",
            "detail": f"{len(blocking)} high/critical vulnerability(s)",
            "ids": [v["id"] for v in blocking],
        })
```

- [ ] **Step 5: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL pass.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/vuln-allowlist.json claude/hooks/package_gate.py tests/test_package_gate.py
git commit -m "feat(package-gate): per-CVE suppression with mandatory expiry"
```

---

## Task 7: 24h caching layer

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_package_gate.py`:

```python
import tempfile
import shutil


class TestCache(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="pkggate-test-")
        self.cache_patch = patch.object(package_gate, "CACHE_DIR", Path(self.cache_dir))
        self.cache_patch.start()

    def tearDown(self):
        self.cache_patch.stop()
        shutil.rmtree(self.cache_dir, ignore_errors=True)

    def test_cache_hit_avoids_http(self):
        cache_key = package_gate._cache_key("npm", "left-pad", "1.0.0")
        cached = {
            "pass": True,
            "failures": [],
            "name": "left-pad",
            "version": "1.0.0",
            "cached_at": datetime.now(timezone.utc).isoformat(),
        }
        package_gate._cache_write(cache_key, cached)

        get_mock = MagicMock()
        post_mock = MagicMock()
        with patch.object(package_gate, "_http_get_json", get_mock), \
             patch.object(package_gate, "_http_post_json", post_mock):
            decision = package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        self.assertTrue(decision["pass"])
        get_mock.assert_not_called()
        post_mock.assert_not_called()

    def test_stale_cache_refreshes(self):
        cache_key = package_gate._cache_key("npm", "left-pad", "1.0.0")
        stale_time = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
        cached = {"pass": True, "failures": [], "cached_at": stale_time}
        package_gate._cache_write(cache_key, cached)

        old_iso = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
        with patch.object(package_gate, "_http_get_json", return_value=npm_registry_response("1.0.0", old_iso)) as gm, \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}):
            package_gate.check_package(
                ecosystem="npm", name="left-pad", version="1.0.0"
            )

        gm.assert_called()
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestCache -v
```

Expected: FAIL — `CACHE_DIR`, `_cache_key`, `_cache_write` don't exist.

- [ ] **Step 3: Implement caching**

In `claude/hooks/package_gate.py`, add:

```python
import hashlib

CACHE_DIR = Path.home() / ".claude" / "cache" / "package-gate"
CACHE_TTL_SECONDS = 24 * 3600


def _cache_key(ecosystem, name, version):
    raw = f"{ecosystem}:{name}:{version}".encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _cache_path(key):
    return CACHE_DIR / f"{key}.json"


def _cache_read(key):
    path = _cache_path(key)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    cached_at_str = data.get("cached_at")
    if not cached_at_str:
        return None
    cached_at = datetime.fromisoformat(cached_at_str)
    age_seconds = (datetime.now(timezone.utc) - cached_at).total_seconds()
    if age_seconds > CACHE_TTL_SECONDS:
        return None
    return data


def _cache_write(key, decision):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = dict(decision)
    payload.setdefault("cached_at", datetime.now(timezone.utc).isoformat())
    _cache_path(key).write_text(json.dumps(payload))
```

Wrap `check_package` body with cache lookup/write. Rename the existing function to `_compute_decision` and add a new `check_package`:

```python
def check_package(ecosystem, name, version):
    key = _cache_key(ecosystem, name, version)
    cached = _cache_read(key)
    if cached is not None:
        return cached
    decision = _compute_decision(ecosystem, name, version)
    _cache_write(key, decision)
    return decision


def _compute_decision(ecosystem, name, version):
    failures = []
    has_provenance = False
    allowlist = _load_allowlist()
    allowlisted = _is_allowlisted(ecosystem, name, allowlist)

    if ecosystem == "npm":
        registry_data = _http_get_json(f"https://registry.npmjs.org/{name}")
        times = registry_data.get("time", {})
        if version not in times:
            failures.append({"check": "RESOLVE", "detail": f"version {version} not found"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        publish_dt = datetime.fromisoformat(times[version].replace("Z", "+00:00"))
        has_provenance = _npm_has_provenance(registry_data, version)
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS and not has_provenance and not allowlisted:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days, no provenance, not allowlisted)",
                "publish_dt": publish_dt.isoformat(),
            })

    vulns = _osv_query(ecosystem, name, version)
    suppressions = _load_vuln_suppressions()
    blocking = [
        v for v in vulns
        if _osv_severity(v) in ("HIGH", "CRITICAL")
        and not _is_vuln_suppressed(v["id"], suppressions)
    ]
    if blocking:
        failures.append({
            "check": "VULNS",
            "detail": f"{len(blocking)} high/critical vulnerability(s)",
            "ids": [v["id"] for v in blocking],
        })

    return {
        "pass": not failures,
        "failures": failures,
        "name": name,
        "version": version,
        "provenance": has_provenance,
        "allowlisted": allowlisted,
    }
```

Also add a helper that returns stale cache entries (we'll use it in Task 8 for network-failure fallback):

```python
def _cache_read_stale(key):
    path = _cache_path(key)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
```

- [ ] **Step 4: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py tests/test_package_gate.py
git commit -m "feat(package-gate): 24h on-disk cache keyed by (ecosystem,name,version)"
```

---

## Task 8: Block output formatting + CLI entry point

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing test for the CLI**

Append to `tests/test_package_gate.py`:

```python
import io


class TestCli(unittest.TestCase):
    def test_cli_exits_zero_on_pass(self):
        old_iso = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
        with patch.object(package_gate, "_http_get_json", return_value=npm_registry_response("1.0.0", old_iso)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}), \
             patch.object(package_gate, "_cache_read", return_value=None), \
             patch.object(package_gate, "_cache_write"):
            code = package_gate.main(["--ecosystem", "npm", "--package", "left-pad@1.0.0"])
        self.assertEqual(code, 0)

    def test_cli_exits_nonzero_on_block_and_prints_findings(self):
        two_days = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        buf = io.StringIO()
        with patch.object(package_gate, "_http_get_json", return_value=npm_registry_response("1.0.0", two_days)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}), \
             patch.object(package_gate, "_cache_read", return_value=None), \
             patch.object(package_gate, "_cache_write"), \
             patch("sys.stderr", buf):
            code = package_gate.main(["--ecosystem", "npm", "--package", "left-pad@1.0.0"])
        self.assertEqual(code, 1)
        output = buf.getvalue()
        self.assertIn("blocked", output.lower())
        self.assertIn("AGE", output)
        self.assertIn("left-pad", output)

    def test_cli_network_failure_falls_back_to_stale_cache(self):
        cache_dir = tempfile.mkdtemp(prefix="pkggate-stale-")
        try:
            with patch.object(package_gate, "CACHE_DIR", Path(cache_dir)):
                key = package_gate._cache_key("npm", "left-pad", "1.0.0")
                stale = {
                    "pass": True,
                    "name": "left-pad",
                    "version": "1.0.0",
                    "failures": [],
                    "cached_at": (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat(),
                }
                package_gate._cache_write(key, stale)

                buf = io.StringIO()
                with patch.object(package_gate, "_http_get_json",
                                  side_effect=urllib.error.URLError("dns")), \
                     patch("sys.stderr", buf):
                    code = package_gate.main(["--ecosystem", "npm", "--package", "left-pad@1.0.0"])

            self.assertEqual(code, 0)
            self.assertIn("stale cache", buf.getvalue())
        finally:
            shutil.rmtree(cache_dir, ignore_errors=True)

    def test_cli_network_failure_no_cache_blocks(self):
        cache_dir = tempfile.mkdtemp(prefix="pkggate-nocache-")
        try:
            with patch.object(package_gate, "CACHE_DIR", Path(cache_dir)), \
                 patch.object(package_gate, "_http_get_json",
                              side_effect=urllib.error.URLError("dns")):
                code = package_gate.main(["--ecosystem", "npm", "--package", "left-pad@1.0.0"])
            self.assertEqual(code, 1)
        finally:
            shutil.rmtree(cache_dir, ignore_errors=True)
```

(Tests use `urllib.error.URLError`; ensure `import urllib.error` is at the top of `test_package_gate.py` — it should already be available via the package_gate import, but add explicitly: `import urllib.error`.)

- [ ] **Step 2: Implement CLI + output formatting**

In `claude/hooks/package_gate.py`, add at the bottom:

```python
def _parse_pkg_arg(pkg_arg, ecosystem):
    if ecosystem == "pip" and "==" in pkg_arg:
        name, _, version = pkg_arg.partition("==")
        return name, version
    if pkg_arg.startswith("@"):
        idx = pkg_arg.find("@", 1)
        if idx == -1:
            return pkg_arg, None
        return pkg_arg[:idx], pkg_arg[idx + 1 :]
    name, sep, version = pkg_arg.partition("@")
    return (name, version) if sep else (name, None)


def _format_block_message(decisions, command):
    lines = ["", "🛑 Package install blocked by claude-setup gate", ""]
    if command:
        lines.append(f"  Command: {command}")
    lines.append("")
    for d in decisions:
        if d["pass"]:
            continue
        ver = d.get("version") or "(latest)"
        lines.append(f"  Findings for {d['name']}@{ver}:")
        for f in d["failures"]:
            lines.append(f"    ✗ {f['check']}: {f['detail']}")
        lines.append("")
    lines.append("  To proceed:")
    lines.append("    • Wait until version turns 7 days old, OR")
    lines.append("    • Add to allowlist: ~/.claude/hooks/package-gate-allowlist.json, OR")
    lines.append("    • One-shot bypass:  CLAUDE_PACKAGE_GATE_SKIP=1 <your install command>")
    lines.append("                        (set CLAUDE_PACKAGE_GATE_REASON=\"...\" to log why)")
    lines.append("")
    lines.append("  Cached for 24h. Re-running won't re-hit the registry.")
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--ecosystem", required=True)
    parser.add_argument("--package", action="append", required=True,
                        help="package or name@version; can be passed multiple times")
    parser.add_argument("--command", default="", help="original shell command for logging")
    args = parser.parse_args(argv)

    decisions = []
    for pkg_arg in args.package:
        name, version = _parse_pkg_arg(pkg_arg, args.ecosystem)
        resolved_version = version or _try_resolve_latest(args.ecosystem, name)
        try:
            decision = check_package(args.ecosystem, name, resolved_version)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
            key = _cache_key(args.ecosystem, name, resolved_version)
            stale = _cache_read_stale(key)
            if stale is not None:
                stale["stale"] = True
                stale["stale_reason"] = f"network failure: {e}"
                sys.stderr.write(
                    f"⚠️  network failure for {name}@{resolved_version}; using stale cache\n"
                )
                decision = stale
            else:
                decision = {
                    "pass": False,
                    "name": name,
                    "version": resolved_version,
                    "failures": [{"check": "NETWORK", "detail": f"could not verify: {e}"}],
                }
        decisions.append(decision)

    blocked = [d for d in decisions if not d["pass"]]
    if blocked:
        sys.stderr.write(_format_block_message(decisions, args.command))
        return 1
    return 0


def _try_resolve_latest(ecosystem, name):
    try:
        return _resolve_latest(ecosystem, name)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError):
        return None


def _resolve_latest(ecosystem, name):
    if ecosystem == "npm":
        data = _http_get_json(f"https://registry.npmjs.org/{name}")
        return data.get("dist-tags", {}).get("latest")
    return None


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL pass.

- [ ] **Step 4: Smoke-test the CLI manually**

```bash
cd ~/claude-setup
python3 claude/hooks/package_gate.py --ecosystem npm --package "react@18.0.0"
echo "exit: $?"
```

Expected: exits 0 (react 18.0.0 is well past 7 days, no high vulns).

- [ ] **Step 5: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py tests/test_package_gate.py
git commit -m "feat(package-gate): CLI entry point with structured block output"
```

---

## Task 9: Bypass env var + audit log

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/test_package_gate.py`:

```python
class TestBypass(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="pkggate-bypass-")
        self.cache_patch = patch.object(package_gate, "CACHE_DIR", Path(self.cache_dir))
        self.cache_patch.start()

    def tearDown(self):
        self.cache_patch.stop()
        shutil.rmtree(self.cache_dir, ignore_errors=True)

    def test_bypass_env_var_exits_zero_and_logs(self):
        with patch.dict(os.environ, {
            "CLAUDE_PACKAGE_GATE_SKIP": "1",
            "CLAUDE_PACKAGE_GATE_REASON": "manual override for test",
        }):
            code = package_gate.main([
                "--ecosystem", "npm",
                "--package", "left-pad@1.0.0",
                "--command", "npm i left-pad@1.0.0",
            ])

        self.assertEqual(code, 0)
        log = (Path(self.cache_dir) / "bypass.log").read_text()
        self.assertIn("left-pad@1.0.0", log)
        self.assertIn("manual override for test", log)

    def test_bypass_without_reason_still_works_but_logs_no_reason(self):
        with patch.dict(os.environ, {"CLAUDE_PACKAGE_GATE_SKIP": "1"}, clear=False):
            os.environ.pop("CLAUDE_PACKAGE_GATE_REASON", None)
            code = package_gate.main([
                "--ecosystem", "npm",
                "--package", "left-pad@1.0.0",
                "--command", "npm i left-pad@1.0.0",
            ])

        self.assertEqual(code, 0)
        log = (Path(self.cache_dir) / "bypass.log").read_text()
        self.assertIn("reason=\"\"", log)
```

- [ ] **Step 2: Implement bypass + logging**

In `claude/hooks/package_gate.py`, add:

```python
import os
import getpass


def _log_bypass(packages, command):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).isoformat()
    reason = os.environ.get("CLAUDE_PACKAGE_GATE_REASON", "")
    user = getpass.getuser()
    cwd = os.getcwd()
    line = (
        f"{ts}\tcommand={command!r}\tpackages={','.join(packages)}\t"
        f"reason=\"{reason}\"\tuser={user}\tcwd={cwd}\n"
    )
    with (CACHE_DIR / "bypass.log").open("a") as f:
        f.write(line)
```

Modify `main` to check bypass before doing any work:

```python
def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--ecosystem", required=True)
    parser.add_argument("--package", action="append", required=True)
    parser.add_argument("--command", default="")
    args = parser.parse_args(argv)

    if os.environ.get("CLAUDE_PACKAGE_GATE_SKIP") == "1":
        _log_bypass(args.package, args.command)
        return 0

    decisions = []
    for pkg_arg in args.package:
        name, version = _parse_pkg_arg(pkg_arg, args.ecosystem)
        resolved_version = version or _try_resolve_latest(args.ecosystem, name)
        try:
            decision = check_package(args.ecosystem, name, resolved_version)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
            key = _cache_key(args.ecosystem, name, resolved_version)
            stale = _cache_read_stale(key)
            if stale is not None:
                stale["stale"] = True
                stale["stale_reason"] = f"network failure: {e}"
                sys.stderr.write(
                    f"⚠️  network failure for {name}@{resolved_version}; using stale cache\n"
                )
                decision = stale
            else:
                decision = {
                    "pass": False,
                    "name": name,
                    "version": resolved_version,
                    "failures": [{"check": "NETWORK", "detail": f"could not verify: {e}"}],
                }
        decisions.append(decision)

    blocked = [d for d in decisions if not d["pass"]]
    if blocked:
        sys.stderr.write(_format_block_message(decisions, args.command))
        return 1
    return 0
```

- [ ] **Step 3: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL pass.

- [ ] **Step 4: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py tests/test_package_gate.py
git commit -m "feat(package-gate): CLAUDE_PACKAGE_GATE_SKIP bypass with audit log"
```

---

## Task 10: Bash dispatcher (Layer 1) — npm only

**Files:**
- Create: `claude/hooks/pre-install-checks.sh`
- Create: `tests/test_pre_install_checks.sh`

- [ ] **Step 1: Write failing dispatcher tests**

Path: `~/claude-setup/tests/test_pre_install_checks.sh`

```bash
#!/usr/bin/env bash
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/claude/hooks/pre-install-checks.sh"
PASS=0
FAIL=0

assert_blocks() {
    local desc="$1" input="$2"
    if TOOL_INPUT="$input" bash "$SCRIPT" >/dev/null 2>&1; then
        echo "FAIL: $desc — should have blocked but exited 0"
        FAIL=$((FAIL+1))
    else
        echo "PASS: $desc"
        PASS=$((PASS+1))
    fi
}

assert_passes() {
    local desc="$1" input="$2"
    if TOOL_INPUT="$input" bash "$SCRIPT" >/dev/null 2>&1; then
        echo "PASS: $desc"
        PASS=$((PASS+1))
    else
        echo "FAIL: $desc — should have passed but exited non-zero"
        FAIL=$((FAIL+1))
    fi
}

export CLAUDE_PACKAGE_GATE_TEST_MODE=1
export CLAUDE_PACKAGE_GATE_TEST_BLOCK_PKG="malicious-young-pkg"

assert_blocks "blocks fresh npm install of malicious-young-pkg" \
    "npm install malicious-young-pkg"
assert_blocks "blocks npm i shorthand" \
    "npm i malicious-young-pkg"
assert_blocks "blocks npm add" \
    "npm add malicious-young-pkg"
assert_blocks "blocks pnpm add" \
    "pnpm add malicious-young-pkg"
assert_blocks "blocks yarn add" \
    "yarn add malicious-young-pkg"
assert_blocks "blocks bun add" \
    "bun add malicious-young-pkg"

assert_passes "passes npm install with no args (lockfile install)" \
    "npm install"
assert_passes "passes yarn (no args, lockfile install)" \
    "yarn"
assert_passes "passes unrelated commands" \
    "ls -la"
assert_passes "passes git commands" \
    "git status"

echo ""
echo "Total: $((PASS+FAIL))  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x ~/claude-setup/tests/test_pre_install_checks.sh
```

- [ ] **Step 2: Run to verify failure (script does not exist yet)**

```bash
bash ~/claude-setup/tests/test_pre_install_checks.sh
```

Expected: every assertion fails because `pre-install-checks.sh` doesn't exist.

- [ ] **Step 3: Implement the dispatcher**

Path: `~/claude-setup/claude/hooks/pre-install-checks.sh`

```bash
#!/usr/bin/env bash
set -u

CMD="${TOOL_INPUT:-}"
[ -z "$CMD" ] && exit 0

ECO=""
PKGS_RAW=""

if echo "$CMD" | grep -qE '\bnpm\s+(i|install|add)\s+[^-]'; then
    ECO="npm"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bnpm\s+(i|install|add)\s+//' | sed -E 's/^\s+//')"
elif echo "$CMD" | grep -qE '\bpnpm\s+(add|install|i)\s+[^-]'; then
    ECO="npm"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bpnpm\s+(add|install|i)\s+//' | sed -E 's/^\s+//')"
elif echo "$CMD" | grep -qE '\byarn\s+add\s+[^-]'; then
    ECO="npm"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\byarn\s+add\s+//' | sed -E 's/^\s+//')"
elif echo "$CMD" | grep -qE '\bbun\s+(add|install|i)\s+[^-]'; then
    ECO="npm"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bbun\s+(add|install|i)\s+//' | sed -E 's/^\s+//')"
fi

[ -z "$ECO" ] && exit 0

PKGS=()
for arg in $PKGS_RAW; do
    case "$arg" in
        -*) ;;
        *)  PKGS+=("$arg") ;;
    esac
done

[ "${#PKGS[@]}" -eq 0 ] && exit 0

if [ "${CLAUDE_PACKAGE_GATE_TEST_MODE:-0}" = "1" ]; then
    for p in "${PKGS[@]}"; do
        name="${p%@*}"
        [ "$name" = "${CLAUDE_PACKAGE_GATE_TEST_BLOCK_PKG:-}" ] && {
            echo "BLOCKED (test mode): $name" >&2
            exit 1
        }
    done
    exit 0
fi

ARGS=(--ecosystem "$ECO" --command "$CMD")
for p in "${PKGS[@]}"; do
    ARGS+=(--package "$p")
done

exec python3 "$HOME/.claude/hooks/package_gate.py" "${ARGS[@]}"
```

Make it executable:

```bash
chmod +x ~/claude-setup/claude/hooks/pre-install-checks.sh
```

- [ ] **Step 4: Run dispatcher tests**

```bash
bash ~/claude-setup/tests/test_pre_install_checks.sh
```

Expected: all 10 assertions PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/pre-install-checks.sh tests/test_pre_install_checks.sh
git commit -m "feat(package-gate): bash dispatcher for npm-family install commands"
```

---

## Task 11: Wrapper layer (Layer 2) with ignore-scripts default

**Files:**
- Create: `claude/hooks/ignore-scripts-allowlist.json`
- Create: `claude/bin/_wrapper.sh`
- Create: 11 symlinks in `claude/bin/`
- Create: `tests/test_wrappers.sh`

- [ ] **Step 1: Create the ignore-scripts allowlist**

Path: `~/claude-setup/claude/hooks/ignore-scripts-allowlist.json`

```json
{
  "_doc": "Packages permitted to run install scripts. Default for npm-family is ignore-scripts=true.",
  "npm": []
}
```

- [ ] **Step 2: Write the wrapper script**

Path: `~/claude-setup/claude/bin/_wrapper.sh`

```bash
#!/usr/bin/env bash
set -u

CALLED_AS="$(basename "$0")"
REAL_BIN=""

for dir in $(echo "$PATH" | tr ':' '\n'); do
    candidate="$dir/$CALLED_AS"
    if [ -x "$candidate" ] && [ "$candidate" != "$HOME/.claude/bin/$CALLED_AS" ]; then
        REAL_BIN="$candidate"
        break
    fi
done

if [ -z "$REAL_BIN" ]; then
    echo "wrapper: cannot find real $CALLED_AS in PATH" >&2
    exit 127
fi

IS_NAMED_INSTALL=0
case "$CALLED_AS" in
    npm|pnpm|bun)
        case "${1:-}" in
            i|install|add)
                if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
                    IS_NAMED_INSTALL=1
                fi
                ;;
        esac
        ;;
    yarn)
        [ "${1:-}" = "add" ] && [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] && IS_NAMED_INSTALL=1
        ;;
    pip|pip3|uv|poetry|cargo|gem)
        case "${1:-}" in
            install|add)
                if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] && [ "$2" != "." ]; then
                    IS_NAMED_INSTALL=1
                fi
                ;;
        esac
        ;;
    go)
        case "${1:-}" in
            get|install)
                if echo "${2:-}" | grep -q '@'; then
                    IS_NAMED_INSTALL=1
                fi
                ;;
        esac
        ;;
esac

if [ "$IS_NAMED_INSTALL" = "1" ] && [ "${CLAUDE_PACKAGE_GATE_WRAPPER_DEPTH:-0}" = "0" ]; then
    export CLAUDE_PACKAGE_GATE_WRAPPER_DEPTH=1

    TOOL_INPUT="$CALLED_AS $*" bash "$HOME/.claude/hooks/pre-install-checks.sh"
    GATE_RC=$?
    if [ "$GATE_RC" -ne 0 ]; then
        exit "$GATE_RC"
    fi
fi

case "$CALLED_AS" in
    npm|pnpm|yarn|bun)
        ALLOWLIST="$HOME/.claude/hooks/ignore-scripts-allowlist.json"
        ALLOWED=0
        if [ "$IS_NAMED_INSTALL" = "1" ] && [ -f "$ALLOWLIST" ]; then
            PKG_NAME="$(echo "${2:-}" | sed -E 's/@.*//')"
            if grep -q "\"$PKG_NAME\"" "$ALLOWLIST" 2>/dev/null; then
                ALLOWED=1
            fi
        fi
        if [ "$ALLOWED" = "0" ]; then
            export npm_config_ignore_scripts=true
        fi
        ;;
esac

exec "$REAL_BIN" "$@"
```

Make it executable:

```bash
chmod +x ~/claude-setup/claude/bin/_wrapper.sh
```

- [ ] **Step 3: Create the 11 symlinks**

```bash
cd ~/claude-setup/claude/bin
for name in npm pnpm yarn bun pip pip3 uv poetry cargo gem go; do
    ln -sf _wrapper.sh "$name"
done
ls -la ~/claude-setup/claude/bin/
```

Expected: 11 symlinks all pointing to `_wrapper.sh`.

- [ ] **Step 4: Write wrapper tests**

Path: `~/claude-setup/tests/test_wrappers.sh`

```bash
#!/usr/bin/env bash
set -u

BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/claude/bin"
PASS=0
FAIL=0

assert_blocks() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: $desc — should have blocked"; FAIL=$((FAIL+1))
    else
        echo "PASS: $desc"; PASS=$((PASS+1))
    fi
}

assert_passes() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc — should have passed"; FAIL=$((FAIL+1))
    fi
}

FAKE_NPM="$(mktemp -d)/npm"
cat > "$FAKE_NPM" <<'EOF'
#!/usr/bin/env bash
echo "fake-npm called: $@"
echo "ignore-scripts=${npm_config_ignore_scripts:-unset}"
exit 0
EOF
chmod +x "$FAKE_NPM"
export PATH="$(dirname "$FAKE_NPM"):$PATH"

export CLAUDE_PACKAGE_GATE_TEST_MODE=1
export CLAUDE_PACKAGE_GATE_TEST_BLOCK_PKG="evil"

assert_blocks "wrapper blocks named install of evil" \
    "$BIN_DIR/npm" install evil

assert_passes "wrapper passes non-install (npm --version)" \
    "$BIN_DIR/npm" --version

assert_passes "wrapper passes lockfile install (npm install no args)" \
    "$BIN_DIR/npm" install

unset CLAUDE_PACKAGE_GATE_TEST_BLOCK_PKG
OUTPUT="$("$BIN_DIR/npm" install lodash 2>&1)"
if echo "$OUTPUT" | grep -q "ignore-scripts=true"; then
    echo "PASS: wrapper sets npm_config_ignore_scripts=true by default"; PASS=$((PASS+1))
else
    echo "FAIL: wrapper did not set npm_config_ignore_scripts"; FAIL=$((FAIL+1))
fi

echo ""
echo "Total: $((PASS+FAIL))  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x ~/claude-setup/tests/test_wrappers.sh
```

- [ ] **Step 5: Run wrapper tests**

```bash
bash ~/claude-setup/tests/test_wrappers.sh
```

Expected: all 4 assertions PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add claude/bin/ claude/hooks/ignore-scripts-allowlist.json tests/test_wrappers.sh
git commit -m "feat(package-gate): PATH-prefixed wrapper layer + ignore-scripts default"
```

---

## Task 12: Wire into settings.json

**Files:**
- Modify: `claude/settings.json`

- [ ] **Step 1: Inspect current settings.json**

```bash
cat ~/claude-setup/claude/settings.json
```

Note the existing `env` block and the existing `PreToolUse` Bash hook command. The current hook command is:

```json
"if echo \"$TOOL_INPUT\" | grep -qE '\\bgit\\s+commit\\b'; then bash $HOME/.claude/hooks/pre-commit-checks.sh; elif echo \"$TOOL_INPUT\" | grep -qE '\\bgit\\s+push\\b'; then bash $HOME/.claude/hooks/pre-push-checks.sh; fi"
```

- [ ] **Step 2: Add PATH prefix to env block**

Edit `~/claude-setup/claude/settings.json`. Change:

```json
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
```

To:

```json
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "PATH": "${HOME}/.claude/bin:${PATH}"
  },
```

- [ ] **Step 3: Add install dispatch branch to the existing PreToolUse hook**

In the same file, change the existing Bash hook command. The new branch is appended as a third `elif`:

```json
"if echo \"$TOOL_INPUT\" | grep -qE '\\bgit\\s+commit\\b'; then bash $HOME/.claude/hooks/pre-commit-checks.sh; elif echo \"$TOOL_INPUT\" | grep -qE '\\bgit\\s+push\\b'; then bash $HOME/.claude/hooks/pre-push-checks.sh; elif echo \"$TOOL_INPUT\" | grep -qE '\\b(npm|pnpm|yarn|bun|pip|pip3|uv|poetry|cargo|gem|go)\\s+(i|install|add|get)\\b'; then bash $HOME/.claude/hooks/pre-install-checks.sh; fi"
```

- [ ] **Step 4: Validate the JSON**

```bash
python3 -m json.tool ~/claude-setup/claude/settings.json > /dev/null && echo OK || echo BROKEN
```

Expected: `OK`.

- [ ] **Step 5: Restart Claude Code to apply settings, then smoke-test**

In a NEW Claude Code session, try:

```bash
# This should pass (react@18.0.0 is old, no high vulns):
npm install react@18.0.0
```

Then in another smoke test:

```bash
# Direct invocation of the wrapper from Claude's PATH:
which npm
# Should print: ~/.claude/bin/npm (the wrapper)
```

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add claude/settings.json
git commit -m "feat(package-gate): wire PATH wrappers + dispatcher into settings.json"
```

---

## Task 13: E2E smoke test with real APIs

**Files:**
- Create: `tests/e2e_smoke.sh`

- [ ] **Step 1: Write the smoke test**

Path: `~/claude-setup/tests/e2e_smoke.sh`

```bash
#!/usr/bin/env bash
set -u

GATE="$HOME/.claude/hooks/package_gate.py"
PASS=0
FAIL=0

assert_pass() {
    local desc="$1"; shift
    if python3 "$GATE" "$@" >/dev/null 2>&1; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc"; FAIL=$((FAIL+1))
    fi
}

assert_block() {
    local desc="$1"; shift
    if python3 "$GATE" "$@" >/dev/null 2>&1; then
        echo "FAIL: $desc — should have blocked"; FAIL=$((FAIL+1))
    else
        echo "PASS: $desc"; PASS=$((PASS+1))
    fi
}

CACHE_DIR="$HOME/.claude/cache/package-gate"
rm -rf "$CACHE_DIR"

assert_pass "react@18.0.0 (old, no high vulns)" \
    --ecosystem npm --package react@18.0.0

assert_block "non-existent typosquat package" \
    --ecosystem npm --package this-package-does-not-exist-xyz123@1.0.0

echo ""
echo "Total: $((PASS+FAIL))  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x ~/claude-setup/tests/e2e_smoke.sh
```

- [ ] **Step 2: Run the smoke test**

```bash
bash ~/claude-setup/tests/e2e_smoke.sh
```

Expected: 2 PASS, 0 FAIL. (Requires network.)

- [ ] **Step 3: Commit**

```bash
cd ~/claude-setup
git add tests/e2e_smoke.sh
git commit -m "test(package-gate): e2e smoke test against real OSV + npm registry"
```

---

## Task 14: Add PyPI ecosystem support

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `claude/hooks/pre-install-checks.sh`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing PyPI tests**

Append to `tests/test_package_gate.py`:

```python
def pypi_response(version, upload_iso):
    return {
        "info": {"version": version, "name": "requests"},
        "releases": {version: [{"upload_time_iso_8601": upload_iso}]},
        "urls": [{"upload_time_iso_8601": upload_iso}],
    }


class TestPypi(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="pkggate-pypi-")
        self.cache_patch = patch.object(package_gate, "CACHE_DIR", Path(self.cache_dir))
        self.cache_patch.start()

    def tearDown(self):
        self.cache_patch.stop()
        shutil.rmtree(self.cache_dir, ignore_errors=True)

    def test_pypi_too_young_blocks(self):
        two_days = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()

        with patch.object(package_gate, "_http_get_json", return_value=pypi_response("2.31.0", two_days)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}):
            decision = package_gate.check_package("pip", "requests", "2.31.0")

        self.assertFalse(decision["pass"])
        self.assertIn("AGE", [f["check"] for f in decision["failures"]])

    def test_pypi_old_version_passes(self):
        old = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()

        with patch.object(package_gate, "_http_get_json", return_value=pypi_response("2.31.0", old)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}):
            decision = package_gate.check_package("pip", "requests", "2.31.0")

        self.assertTrue(decision["pass"])
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestPypi -v
```

Expected: FAIL — pip ecosystem not implemented.

- [ ] **Step 3: Implement PyPI branch**

In `claude/hooks/package_gate.py`, inside `_compute_decision`, add an `elif` branch for `pip`:

```python
    elif ecosystem == "pip":
        url = f"https://pypi.org/pypi/{name}/{version}/json"
        try:
            data = _http_get_json(url)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                failures.append({"check": "RESOLVE", "detail": f"version {version} not found on PyPI"})
                return {"pass": False, "failures": failures, "name": name, "version": version}
            raise
        upload_times = [
            datetime.fromisoformat(u["upload_time_iso_8601"].replace("Z", "+00:00"))
            for u in data.get("urls", [])
            if "upload_time_iso_8601" in u
        ]
        if not upload_times:
            failures.append({"check": "RESOLVE", "detail": "no upload timestamps found"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        publish_dt = min(upload_times)
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS and not allowlisted:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days)",
                "publish_dt": publish_dt.isoformat(),
            })
```

Also extend `_resolve_latest`:

```python
def _resolve_latest(ecosystem, name):
    if ecosystem == "npm":
        data = _http_get_json(f"https://registry.npmjs.org/{name}")
        return data.get("dist-tags", {}).get("latest")
    if ecosystem == "pip":
        data = _http_get_json(f"https://pypi.org/pypi/{name}/json")
        return data.get("info", {}).get("version")
    return None
```

- [ ] **Step 4: Extend the bash dispatcher to detect pip/uv/poetry**

Edit `claude/hooks/pre-install-checks.sh`. After the existing `bun` branch, add:

```bash
elif echo "$CMD" | grep -qE '\b(pip|pip3)\s+install\s+[^-]'; then
    if echo "$CMD" | grep -qE '\bpip3?\s+install\s+(-r|-e|\.\s|\.$)'; then
        exit 0
    fi
    ECO="pip"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bpip3?\s+install\s+//' | sed -E 's/^\s+//')"
elif echo "$CMD" | grep -qE '\buv\s+(add|pip\s+install)\s+[^-]'; then
    ECO="pip"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\buv\s+(add|pip\s+install)\s+//' | sed -E 's/^\s+//')"
elif echo "$CMD" | grep -qE '\bpoetry\s+add\s+[^-]'; then
    ECO="pip"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bpoetry\s+add\s+//' | sed -E 's/^\s+//')"
```

Also update the `_parse_pkg_arg` calls implicitly — `pip` uses `==` for version. The existing `_parse_pkg_arg` already handles `==` for pip.

- [ ] **Step 5: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
bash ~/claude-setup/tests/test_pre_install_checks.sh
```

Expected: ALL pass.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py claude/hooks/pre-install-checks.sh tests/test_package_gate.py
git commit -m "feat(package-gate): add PyPI ecosystem (pip, uv, poetry)"
```

---

## Task 15: Add crates.io (cargo) ecosystem support

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `claude/hooks/pre-install-checks.sh`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing cargo test**

Append to `tests/test_package_gate.py`:

```python
def crates_response(version, created_iso):
    return {
        "crate": {"name": "serde", "max_version": version},
        "versions": [{"num": version, "created_at": created_iso}],
    }


class TestCrates(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="pkggate-crates-")
        self.cache_patch = patch.object(package_gate, "CACHE_DIR", Path(self.cache_dir))
        self.cache_patch.start()

    def tearDown(self):
        self.cache_patch.stop()
        shutil.rmtree(self.cache_dir, ignore_errors=True)

    def test_cargo_too_young_blocks(self):
        two_days = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        with patch.object(package_gate, "_http_get_json", return_value=crates_response("1.0.193", two_days)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}):
            decision = package_gate.check_package("cargo", "serde", "1.0.193")
        self.assertFalse(decision["pass"])
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestCrates -v
```

Expected: FAIL.

- [ ] **Step 3: Implement cargo branch**

In `claude/hooks/package_gate.py`, add another `elif` to `_compute_decision`:

```python
    elif ecosystem == "cargo":
        data = _http_get_json(f"https://crates.io/api/v1/crates/{name}")
        match = next((v for v in data.get("versions", []) if v.get("num") == version), None)
        if match is None:
            failures.append({"check": "RESOLVE", "detail": f"version {version} not found on crates.io"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        publish_dt = datetime.fromisoformat(match["created_at"].replace("Z", "+00:00"))
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS and not allowlisted:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days)",
                "publish_dt": publish_dt.isoformat(),
            })
```

Extend `_resolve_latest`:

```python
    if ecosystem == "cargo":
        data = _http_get_json(f"https://crates.io/api/v1/crates/{name}")
        return data.get("crate", {}).get("max_version")
```

- [ ] **Step 4: Extend bash dispatcher**

In `claude/hooks/pre-install-checks.sh`, after the poetry branch:

```bash
elif echo "$CMD" | grep -qE '\bcargo\s+(add|install)\s+[^-]'; then
    ECO="cargo"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bcargo\s+(add|install)\s+//' | sed -E 's/^\s+//')"
```

- [ ] **Step 5: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL pass.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py claude/hooks/pre-install-checks.sh tests/test_package_gate.py
git commit -m "feat(package-gate): add crates.io (cargo) ecosystem"
```

---

## Task 16: Add RubyGems (gem) ecosystem support

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `claude/hooks/pre-install-checks.sh`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing gem test**

Append to `tests/test_package_gate.py`:

```python
def rubygems_response(version, created_iso):
    return [
        {"number": version, "created_at": created_iso},
        {"number": "0.9.0", "created_at": "2020-01-01T00:00:00Z"},
    ]


class TestRubyGems(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="pkggate-gem-")
        self.cache_patch = patch.object(package_gate, "CACHE_DIR", Path(self.cache_dir))
        self.cache_patch.start()

    def tearDown(self):
        self.cache_patch.stop()
        shutil.rmtree(self.cache_dir, ignore_errors=True)

    def test_gem_too_young_blocks(self):
        two_days = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        with patch.object(package_gate, "_http_get_json", return_value=rubygems_response("3.0.0", two_days)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}):
            decision = package_gate.check_package("gem", "rails", "3.0.0")
        self.assertFalse(decision["pass"])
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestRubyGems -v
```

Expected: FAIL.

- [ ] **Step 3: Implement gem branch in `_compute_decision`**

```python
    elif ecosystem == "gem":
        data = _http_get_json(f"https://rubygems.org/api/v1/versions/{name}.json")
        match = next((v for v in data if v.get("number") == version), None)
        if match is None:
            failures.append({"check": "RESOLVE", "detail": f"version {version} not found on RubyGems"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        publish_dt = datetime.fromisoformat(match["created_at"].replace("Z", "+00:00"))
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS and not allowlisted:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days)",
                "publish_dt": publish_dt.isoformat(),
            })
```

Extend `_resolve_latest`:

```python
    if ecosystem == "gem":
        data = _http_get_json(f"https://rubygems.org/api/v1/versions/{name}/latest.json")
        return data.get("version")
```

- [ ] **Step 4: Extend bash dispatcher**

In `claude/hooks/pre-install-checks.sh`, after cargo:

```bash
elif echo "$CMD" | grep -qE '\bgem\s+install\s+[^-]'; then
    ECO="gem"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bgem\s+install\s+//' | sed -E 's/^\s+//')"
```

- [ ] **Step 5: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL pass.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py claude/hooks/pre-install-checks.sh tests/test_package_gate.py
git commit -m "feat(package-gate): add RubyGems (gem) ecosystem"
```

---

## Task 17: Add Go modules ecosystem support

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `claude/hooks/pre-install-checks.sh`
- Modify: `tests/test_package_gate.py`

- [ ] **Step 1: Write failing go test**

Append to `tests/test_package_gate.py`:

```python
def go_response(time_iso):
    return {"Version": "v1.0.0", "Time": time_iso}


class TestGo(unittest.TestCase):
    def setUp(self):
        self.cache_dir = tempfile.mkdtemp(prefix="pkggate-go-")
        self.cache_patch = patch.object(package_gate, "CACHE_DIR", Path(self.cache_dir))
        self.cache_patch.start()

    def tearDown(self):
        self.cache_patch.stop()
        shutil.rmtree(self.cache_dir, ignore_errors=True)

    def test_go_too_young_blocks(self):
        two_days = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        with patch.object(package_gate, "_http_get_json", return_value=go_response(two_days)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}):
            decision = package_gate.check_package("go", "example.com/foo", "v1.0.0")
        self.assertFalse(decision["pass"])
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestGo -v
```

Expected: FAIL.

- [ ] **Step 3: Implement go branch in `_compute_decision`**

```python
    elif ecosystem == "go":
        url = f"https://proxy.golang.org/{name}/@v/{version}.info"
        try:
            data = _http_get_json(url)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                failures.append({"check": "RESOLVE", "detail": f"version {version} not found"})
                return {"pass": False, "failures": failures, "name": name, "version": version}
            raise
        time_str = data.get("Time")
        if not time_str:
            failures.append({"check": "RESOLVE", "detail": "no Time field on proxy response"})
            return {"pass": False, "failures": failures, "name": name, "version": version}
        publish_dt = datetime.fromisoformat(time_str.replace("Z", "+00:00"))
        age = _age_days(publish_dt)
        if age < AGE_THRESHOLD_DAYS and not allowlisted:
            failures.append({
                "check": "AGE",
                "detail": f"published {age} days ago (threshold: {AGE_THRESHOLD_DAYS} days)",
                "publish_dt": publish_dt.isoformat(),
            })
```

Extend `_resolve_latest`:

```python
    if ecosystem == "go":
        data = _http_get_json(f"https://proxy.golang.org/{name}/@latest")
        return data.get("Version")
```

- [ ] **Step 4: Extend bash dispatcher**

In `claude/hooks/pre-install-checks.sh`, after gem:

```bash
elif echo "$CMD" | grep -qE '\bgo\s+(get|install)\s+[^-]+@'; then
    ECO="go"
    PKGS_RAW="$(echo "$CMD" | sed -E 's/.*\bgo\s+(get|install)\s+//' | sed -E 's/^\s+//')"
```

- [ ] **Step 5: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
bash ~/claude-setup/tests/test_pre_install_checks.sh
bash ~/claude-setup/tests/test_wrappers.sh
```

Expected: ALL pass.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py claude/hooks/pre-install-checks.sh tests/test_package_gate.py
git commit -m "feat(package-gate): add Go modules ecosystem"
```

---

## Task 18: Warn-only mode rollout helper

**Files:**
- Modify: `claude/hooks/package_gate.py`
- Modify: `tests/test_package_gate.py`

Per spec Rollout step 2: ship in warn-only mode for one week before flipping to hard-block. This task adds the env-var toggle.

- [ ] **Step 1: Write failing test**

Append to `tests/test_package_gate.py`:

```python
class TestWarnOnly(unittest.TestCase):
    def test_warn_only_mode_logs_but_exits_zero(self):
        two_days = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        buf = io.StringIO()
        with patch.dict(os.environ, {"CLAUDE_PACKAGE_GATE_WARN_ONLY": "1"}), \
             patch.object(package_gate, "_http_get_json", return_value=npm_registry_response("1.0.0", two_days)), \
             patch.object(package_gate, "_http_post_json", return_value={"vulns": []}), \
             patch.object(package_gate, "_load_allowlist", return_value={}), \
             patch.object(package_gate, "_load_vuln_suppressions", return_value={}), \
             patch.object(package_gate, "_cache_read", return_value=None), \
             patch.object(package_gate, "_cache_write"), \
             patch("sys.stderr", buf):
            code = package_gate.main(["--ecosystem", "npm", "--package", "left-pad@1.0.0"])
        self.assertEqual(code, 0)
        self.assertIn("WARN-ONLY", buf.getvalue())
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate.TestWarnOnly -v
```

Expected: FAIL.

- [ ] **Step 3: Implement warn-only mode**

In `claude/hooks/package_gate.py`, modify `main` after the decisions loop:

```python
    blocked = [d for d in decisions if not d["pass"]]
    if blocked:
        msg = _format_block_message(decisions, args.command)
        if os.environ.get("CLAUDE_PACKAGE_GATE_WARN_ONLY") == "1":
            sys.stderr.write("⚠️  WARN-ONLY MODE: would have blocked, allowing through\n")
            sys.stderr.write(msg)
            _log_warn_only(args.package, args.command, decisions)
            return 0
        sys.stderr.write(msg)
        return 1
    return 0


def _log_warn_only(packages, command, decisions):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).isoformat()
    summary = json.dumps([{"name": d["name"], "fail": [f["check"] for f in d["failures"]]} for d in decisions])
    line = f"{ts}\tcommand={command!r}\tdecisions={summary}\n"
    with (CACHE_DIR / "warn-only.log").open("a") as f:
        f.write(line)
```

- [ ] **Step 4: Run all tests**

```bash
cd ~/claude-setup && python3 -m unittest tests.test_package_gate -v
```

Expected: ALL pass.

- [ ] **Step 5: Document the rollout flag in README**

Add to `~/claude-setup/README.md` under setup notes (or wherever hooks are documented):

```markdown
### Package install gate

Two-layer gate that blocks installs of newly-published or vulnerable packages.
See `docs/superpowers/specs/2026-05-15-package-install-gate-design.md`.

**Rollout flag:**
- `CLAUDE_PACKAGE_GATE_WARN_ONLY=1` (default for week 1) — log but do not block
- Remove the env var (default behavior) — hard-block on failure
```

- [ ] **Step 6: Set warn-only mode in settings.json for week 1**

Edit `~/claude-setup/claude/settings.json` env block:

```json
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "PATH": "${HOME}/.claude/bin:${PATH}",
    "CLAUDE_PACKAGE_GATE_WARN_ONLY": "1"
  },
```

After one week of monitoring `~/.claude/cache/package-gate/warn-only.log`, remove this line to flip to hard-block.

- [ ] **Step 7: Final commit**

```bash
cd ~/claude-setup
git add claude/hooks/package_gate.py claude/settings.json tests/test_package_gate.py README.md
git commit -m "feat(package-gate): warn-only rollout mode + README docs"
```

---

## Task 19: CI workflow

**Files:**
- Create: `.github/workflows/package-gate-tests.yml`

- [ ] **Step 1: Create the workflow**

Path: `~/claude-setup/.github/workflows/package-gate-tests.yml`

```yaml
name: package-gate-tests

on:
  pull_request:
    paths:
      - "claude/hooks/package_gate.py"
      - "claude/hooks/pre-install-checks.sh"
      - "claude/bin/**"
      - "tests/**"
      - ".github/workflows/package-gate-tests.yml"
  push:
    branches: [main]
    paths:
      - "claude/hooks/package_gate.py"
      - "claude/hooks/pre-install-checks.sh"
      - "claude/bin/**"
      - "tests/**"

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Python unit tests
        run: python3 -m unittest tests.test_package_gate -v
      - name: Dispatcher tests
        run: bash tests/test_pre_install_checks.sh
      - name: Wrapper tests
        run: bash tests/test_wrappers.sh

  smoke:
    runs-on: ubuntu-latest
    needs: unit
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install hooks to fake $HOME so absolute paths resolve
        run: |
          mkdir -p $HOME/.claude/hooks $HOME/.claude/bin
          cp claude/hooks/package_gate.py $HOME/.claude/hooks/
          cp claude/hooks/*.json $HOME/.claude/hooks/
          chmod +x claude/hooks/pre-install-checks.sh
          cp claude/hooks/pre-install-checks.sh $HOME/.claude/hooks/
      - name: E2E smoke (real APIs)
        run: bash tests/e2e_smoke.sh
```

- [ ] **Step 2: Verify the workflow file is valid YAML**

```bash
cd ~/claude-setup
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/package-gate-tests.yml'))" 2>/dev/null && echo OK || echo "yaml.safe_load failed (PyYAML may not be installed) — falling back to GitHub validation on push"
```

If PyYAML isn't available, validation happens when GitHub receives the file.

- [ ] **Step 3: Commit**

```bash
cd ~/claude-setup
git add .github/workflows/package-gate-tests.yml
git commit -m "ci(package-gate): run unit + dispatcher + wrapper + e2e tests on PRs"
```

- [ ] **Step 4: Push and verify the workflow runs**

```bash
cd ~/claude-setup
git push
```

Open the latest commit on `github.com/luke-guider/claude-setup` and confirm the `package-gate-tests` workflow runs green. If anything is red, fix and push another commit — do not declare done until CI is green.

---

## Final verification

After Task 18, run the full test matrix:

```bash
cd ~/claude-setup
python3 -m unittest tests.test_package_gate -v
bash tests/test_pre_install_checks.sh
bash tests/test_wrappers.sh
bash tests/e2e_smoke.sh
```

All four must pass. If anything is red, do not push.

Push when green:

```bash
git push
```
