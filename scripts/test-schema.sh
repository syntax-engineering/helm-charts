#!/usr/bin/env bash
# Every tests/schema/good file must render; every bad file must fail with its "# expect:" text.
set -euo pipefail
chart=charts/syntax-workload
fail=0
for f in "$chart"/tests/schema/good/*.yaml; do
  if ! out=$(helm template t "$chart" -f "$f" 2>&1); then
    echo "FAIL (should render): $f"; echo "$out" | head -5; fail=1
  fi
done
for f in "$chart"/tests/schema/bad/*.yaml; do
  expect=$(sed -n '1s/^# expect: //p' "$f")
  [ -n "$expect" ] || { echo "FAIL (no # expect: line): $f"; fail=1; continue; }
  if out=$(helm template t "$chart" -f "$f" 2>&1); then
    echo "FAIL (should not render): $f"; fail=1
  elif ! grep -qF "$expect" <<<"$out"; then
    echo "FAIL (wrong error): $f"; echo "  wanted: $expect"; echo "$out" | head -5 | sed 's/^/  got: /'; fail=1
  fi
done
[ $fail -eq 0 ] && echo "schema: all cases passed"
exit $fail
