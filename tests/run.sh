#!/usr/bin/env bash
# Run every tests/test_*.sh; exit non-zero if any assertion failed.
# Invoke from anywhere, e.g. `bash tests/run.sh` from the repo root.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"; export REPO_ROOT
cd "$HERE" || exit 1
TOTAL_PASS=0; TOTAL_FAIL=0
for t in test_*.sh; do
  [ -e "$t" ] || continue
  echo "── $t ──"
  # shellcheck disable=SC1090
  TESTS_PASS=0; TESTS_FAIL=0; source "./lib.sh"; source "./$t"
  TOTAL_PASS=$((TOTAL_PASS+TESTS_PASS)); TOTAL_FAIL=$((TOTAL_FAIL+TESTS_FAIL))
done
echo "── total: $TOTAL_PASS passed, $TOTAL_FAIL failed ──"
[ "$TOTAL_FAIL" -eq 0 ]
