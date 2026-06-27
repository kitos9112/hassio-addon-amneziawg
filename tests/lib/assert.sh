#!/usr/bin/env bash
# Minimal test assertion helpers. Source this, call asserts, end with assert_summary.

ASSERT_PASS=0
ASSERT_FAIL=0

_pass() { ASSERT_PASS=$((ASSERT_PASS + 1)); printf '  ok   %s\n' "$1"; }
_fail() { ASSERT_FAIL=$((ASSERT_FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }

assert_eq() { # expected actual msg
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (expected '$1', got '$2')"; fi
}

assert_file() { # path msg
  if [ -f "$1" ]; then _pass "$2"; else _fail "$2 (missing file: $1)"; fi
}

assert_contains() { # file pattern msg
  if grep -qE -- "$2" "$1" 2>/dev/null; then _pass "$3"; else _fail "$3 (pattern '$2' not found in $1)"; fi
}

assert_not_contains() { # file pattern msg
  if grep -qE -- "$2" "$1" 2>/dev/null; then _fail "$3 (pattern '$2' unexpectedly present in $1)"; else _pass "$3"; fi
}

assert_mode() { # path expected_mode msg
  local m
  m="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
  if [ "$m" = "$2" ]; then _pass "$3"; else _fail "$3 (mode $m != $2 on $1)"; fi
}

assert_ok() { # msg cmd...
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then _pass "$msg"; else _fail "$msg (command failed: $*)"; fi
}

assert_fail() { # msg cmd...
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then _fail "$msg (command unexpectedly succeeded: $*)"; else _pass "$msg"; fi
}

assert_summary() {
  printf '\n== %d passed, %d failed ==\n' "$ASSERT_PASS" "$ASSERT_FAIL"
  [ "$ASSERT_FAIL" -eq 0 ]
}
