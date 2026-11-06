# helm-charts

Shared Helm charts for Syntax workloads. Each chart lives in `charts/<name>/` and is published to
`oci://ghcr.io/syntax-engineering/charts/<name>`.

| Chart | Purpose |
|---|---|
| `syntax-workload` | Standard Rails web, worker, cronjob, and deploy-hook workloads |

## Working on a chart

    mise install
    helm plugin install https://github.com/helm-unittest/helm-unittest --version "$HELM_UNITTEST_VERSION"
    just test

## Previewing a chart change in an app repo

    just render-diff ../acme deploy/overlays/staging origin/main [chart-dir]

Renders the overlay (`kustomize build --enable-helm`) at the base ref with the chart version the app
pins, and at the app repo's HEAD with this checkout's chart packaged locally (default
`charts/syntax-workload`, so unpublished changes work), then prints per-object added, removed, and
modified counts with a unified diff for each modified object. The app repo is never modified, and it
exits non-zero if either render fails.

## Releasing

Bump `version` in the chart's `Chart.yaml`, add a `CHANGELOG.md` entry, merge, then push a tag named
`<chart>-v<version>` (for example `syntax-workload-v0.1.0`). The release workflow publishes it.
