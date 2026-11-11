#!/usr/bin/env python
"""Reconcile README's test table against the suites Foundry actually ran.

Why this exists: the README once claimed "42 tests, all green" while the tree
ran 177. A stale number is the cheapest possible lie -- everyone downstream
quotes it in good faith. So the table is not allowed to be hand-maintained
without proof.

Usage:
    python tools/readme_reconcile.py                # check README.md
    python tools/readme_reconcile.py --readme X.md  # check another table (negative control)
    python tools/readme_reconcile.py --json-only    # dump measured counts, no README

Exit codes: 0 = table matches the run; 1 = mismatch; 2 = could not run.
"""

import argparse
import json
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_foundry():
    proc = subprocess.run(
        ["forge", "test", "--json"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if not proc.stdout.strip():
        print("[reconcile] FATAL: forge produced no JSON. stderr tail:")
        print((proc.stderr or "")[-800:])
        sys.exit(2)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        print(f"[reconcile] FATAL: unparsable forge JSON: {exc}")
        sys.exit(2)
    if proc.returncode != 0:
        print(f"[reconcile] FATAL: forge test exit={proc.returncode} (tests are red; fix that first)")
        sys.exit(2)
    return data


def measured(data):
    """suite name -> test count, plus failures."""
    out = {}
    failed = 0
    for key, suite in data.items():
        name = key.split(":")[-1]
        results = suite.get("test_results") or {}
        out[name] = out.get(name, 0) + len(results)
        for r in results.values():
            if r.get("status") not in ("Success", "Skipped"):
                failed += 1
    return out, failed


ROW = re.compile(r"^\|\s*`([^`]+)`[^|]*\|\s*\*{0,2}(\d+)\*{0,2}\s*\|\s*$")
TOTAL = re.compile(r"^\|\s*\*{0,2}Total\*{0,2}\s*\|\s*\*{0,2}(\d+)\*{0,2}\s*\|\s*$")


def parse_readme(path):
    rows = {}
    total = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip()
            m = TOTAL.match(line)
            if m:
                total = int(m.group(1))
                continue
            m = ROW.match(line)
            if m:
                rows[m.group(1)] = int(m.group(2))
    return rows, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--readme", default=os.path.join(ROOT, "README.md"))
    ap.add_argument("--json-only", action="store_true")
    args = ap.parse_args()

    data = run_foundry()
    counts, failed = measured(data)
    n_tests = sum(counts.values())
    n_suites = len(counts)

    print(f"[reconcile] measured: {n_tests} tests / {n_suites} suites, {failed} failed")
    if args.json_only:
        print(json.dumps({"tests": n_tests, "suites": n_suites, "per_suite": counts}, indent=2))
        return 0 if failed == 0 else 1

    if failed:
        print("[reconcile] RED: suite failures present, README table is moot")
        return 1

    rows, total = parse_readme(args.readme)
    if total is None:
        print(f"[reconcile] RED: no '| **Total** | N |' row in {args.readme}")
        return 1

    problems = []
    for name, n in sorted(counts.items()):
        if name not in rows:
            problems.append(f"missing from table: {name} ({n} tests)")
        elif rows[name] != n:
            problems.append(f"count drift: {name} table={rows[name]} actual={n}")
    for name, n in sorted(rows.items()):
        if name not in counts:
            problems.append(f"table lists a suite that did not run: {name} ({n})")
    if total != n_tests:
        problems.append(f"total drift: table={total} actual={n_tests}")

    if problems:
        print(f"[reconcile] RED: {len(problems)} problem(s)")
        for p in problems:
            print(f"  - {p}")
        return 1

    print(f"[reconcile] GREEN: table == run ({n_tests} tests / {n_suites} suites)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
