#!/usr/bin/env bash
# Minimal assertion helpers for the bash test scripts. Source this.
TESTS_PASS=0; TESTS_FAIL=0
_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; TESTS_PASS=$((TESTS_PASS+1)); }
_bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; TESTS_FAIL=$((TESTS_FAIL+1)); }

assert_eq()       { [ "$2" = "$3" ] && _ok "$1" || { _bad "$1"; printf '       expected [%s] got [%s]\n' "$3" "$2"; }; }
assert_contains() { case "$2" in *"$3"*) _ok "$1";; *) _bad "$1"; printf '       [%s] missing [%s]\n' "$2" "$3";; esac; }
assert_not_eq()   { [ "$2" != "$3" ] && _ok "$1" || { _bad "$1"; printf '       both [%s]\n' "$2"; }; }
# assert_fail "label" some_command...  → passes if the command exits non-zero
assert_fail()     { local l="$1"; shift; if "$@" >/dev/null 2>&1; then _bad "$l (expected failure)"; else _ok "$l"; fi; }
