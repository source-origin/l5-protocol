#!/usr/bin/env sh
# scripts/verify.sh — deterministic repro of this repo's test suite.
# Requires only: git, foundry (forge). No network beyond git submodules.
# Usage:  sh scripts/verify.sh
set -eu

cd "$(dirname "$0")/.."

echo "== fetching pinned deps =="
git submodule update --init --recursive

echo
echo "== test functions by file =="
total=0
for f in test/*.t.sol; do
  n=$(grep -c 'function test' "$f" || true)
  total=$((total + n))
  printf '%3d  %s\n' "$n" "$f"
done
printf '%3d  %s\n' "$total" "TOTAL (test/*.t.sol)"

echo
echo "== forge test =="
forge test -vv

echo
echo "== done: if forge printed 'test result: ok', the count above is reproducible =="
