# helm-charts

Shared Helm charts for Syntax workloads. Each chart lives in `charts/<name>/` and is published to
`oci://ghcr.io/syntax-engineering/charts/<name>`.

| Chart | Purpose |
|---|---|
| `syntax-workload` | Standard Rails web, worker, cronjob, and deploy-hook workloads |

## Working on a chart

    mise install
    helm plugin install https://github.com/helm-unittest/helm-unittest --version "$HELM_UNITTEST_VERSION"
    make test

## Releasing

Bump `version` in the chart's `Chart.yaml`, add a `CHANGELOG.md` entry, merge, then push a tag named
`<chart>-v<version>` (for example `syntax-workload-v0.1.0`). The release workflow publishes it.
