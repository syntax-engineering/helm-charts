#!/usr/bin/env bash
# For each tests/parity/<app>, the chart's output must equal the legacy manifests after Kustomize normalizes both.
set -euo pipefail
chart=charts/syntax-workload
work=$(mktemp -d "${TMPDIR:-/tmp}/parity.XXXX")
trap 'rm -rf "$work"' EXIT
fail=0
normalize() { # $1 = dir of manifests, $2 = output file
  (
    cd "$1"
    shopt -s nullglob
    printf 'resources:\n' > kustomization.yml
    for f in *.yml *.yaml; do
      [ "$f" = kustomization.yml ] || echo "  - $f" >> kustomization.yml
    done
  )
  kustomize build "$1" > "$2"
}
for dir in "$chart"/tests/parity/*/; do
  app=$(basename "$dir")
  mkdir -p "$work/$app/expected" "$work/$app/rendered"
  cp "$dir"/expected/*.yml "$work/$app/expected/"
  helm template "$app" "$chart" -f "$dir/values.yaml" > "$work/$app/rendered/chart.yaml"
  normalize "$work/$app/expected" "$work/$app/expected.out"
  normalize "$work/$app/rendered" "$work/$app/rendered.out"
  if diff -u "$work/$app/expected.out" "$work/$app/rendered.out"; then
    echo "parity: $app matches"
  else
    echo "parity: $app DIFFERS (lines starting with + are what the chart adds)"; fail=1
  fi
done
exit $fail
