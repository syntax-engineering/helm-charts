#!/usr/bin/env bash
# The chart's standard fixture must pass every policy with zero failures.
set -euo pipefail
chart=charts/syntax-workload
out=$(mktemp "${TMPDIR:-/tmp}/standard.XXXX.yaml")
trap 'rm -f "$out"' EXIT
helm template standard "$chart" -f "$chart/tests/values/standard.yaml" > "$out"
report=$(kyverno apply policies/ --resource "$out" 2>&1) || true
echo "$report" | grep -vE '^\s*$' | tail -20
summary=$(grep -E 'pass: [0-9]+, fail: [0-9]+' <<<"$report" | tail -1)
[ -n "$summary" ] || { echo "policy: could not read the Kyverno summary"; exit 1; }
grep -qE 'pass: [1-9][0-9]*,' <<<"$summary" || { echo "policy: no passing rules in the Kyverno summary (pass: 0)"; exit 1; }
grep -qE 'fail: 0, warn: [0-9]+, error: 0' <<<"$summary" || { echo "policy: failures above"; exit 1; }
scripts/cross-check.sh "$out"
