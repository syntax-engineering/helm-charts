#!/usr/bin/env bash
# Rules that span objects: every Deployment has a PDB selecting it and a VPA targeting it.
set -euo pipefail
f=$1; rc=0
canon='.spec.selector.matchLabels | to_entries | sort_by(.key) | map(.key + "=" + .value) | join(",")'
pdbs=$(yq -N "select(.kind==\"PodDisruptionBudget\") | $canon" "$f")
for d in $(yq -N 'select(.kind=="Deployment") | .metadata.name' "$f"); do
  sel=$(yq -N "select(.kind==\"Deployment\" and .metadata.name==\"$d\") | $canon" "$f")
  grep -qxF "$sel" <<<"$pdbs" || { echo "FAIL $d: no PodDisruptionBudget selects it"; rc=1; }
  yq -N -e "select(.kind==\"VerticalPodAutoscaler\" and .spec.targetRef.name==\"$d\")" "$f" >/dev/null 2>&1 \
    || { echo "FAIL $d: no VerticalPodAutoscaler targets it"; rc=1; }
done
[ $rc -eq 0 ] && echo "cross-check: every Deployment has a PDB and a VPA"
exit $rc
