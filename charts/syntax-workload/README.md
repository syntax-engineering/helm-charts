# syntax-workload

Declares Rails web apps, Sidekiq workers, cronjobs, and Argo CD deploy hooks with our standards built
in. Apps render it from their Kustomize overlays with `helmCharts:`.

## Using it

```yaml
# kubernetes/overlays/<env>/kustomization.yml
helmCharts:
  - name: syntax-workload
    repo: oci://ghcr.io/syntax-engineering/charts
    version: 0.2.0
    releaseName: <app>
    valuesFile: ../../base/workloads/values.yml
    additionalValuesFiles: [workloads.values.yml]
```

Argo CD must run Kustomize with `--enable-helm --load-restrictor LoadRestrictionsNone`.

## App-wide fields

| Field | Required | Meaning |
|---|---|---|
| `app` | yes | The `app` label and the name prefix |
| `namespace` | yes | Namespace for every object |
| `image` | yes | Container image; CI bumps it with Kustomize `images:` |
| `imagePullSecret` | no | One pull secret name |
| `serviceAccount` | no | Default service account |
| `nodeSelector` | no | Default node selector |
| `priorityClassName` | no | Default priority class for every pod |
| `envFrom.configMaps`, `envFrom.secrets` | no | Env sources, config maps first |
| `prometheus.serverAddress` | when autoscaling | Prometheus for KEDA triggers |

## Workloads

`workloads` is a map. The key is the workload name; the object is named `<app>-<key>` unless
`fullName` is set.

| Kind | Required | Generates |
|---|---|---|
| `Web` | `port`, `replicas`, `healthPath` (unless `probes: false`) | Deployment, Service, PDB, VPA, ScaledObject when autoscaling |
| `Worker` | `replicas` | Deployment, PDB, VPA, ScaledObject when autoscaling |
| `CronJob` | `schedule`, `command` | CronJob |
| `Hook` | `phase` (`PreSync`, `Sync`, `PostSync`), `command` | Job with Argo CD hook annotations |

`replicas` is an integer, or `{min, max}` when `autoscaling` is set. The minimum is 2.

Every workload can set `command`, `args`, `env`, `envFrom`, `serviceAccount`, `nodeSelector`,
`priorityClassName` (`false` omits it), `resources`, `volumes`, `volumeMounts`, `selectorLabels`, and
`enabled: false`.

`selectorLabels` adds labels to the workload's selector, pod labels, spread, PDB, and Service. Use it
when several workloads share a `role`. Selectors are immutable, so set it once. Deployments and
Services also carry their selector as `metadata.labels`.

## Defaults

| Setting | Default |
|---|---|
| Resources | requests 1000m / 2Gi, limits 2000m / 4Gi |
| VPA | recommendation-only, min 500m / 1Gi, max 4000m / 8Gi |
| PDB | `maxUnavailable: 1` |
| Spread | soft, one per hostname, `matchLabelKeys: [pod-template-hash]` |
| Strategy | RollingUpdate, maxSurge 25%, maxUnavailable 0 |
| Web probes | startup (5 min), readiness, liveness on `healthPath` |
| KEDA | fallback to `replicas.min` after 3 failures; 5-minute scale-down stabilization |
| CronJob | Forbid concurrency, 1-hour deadline, keep 3 succeeded and 3 failed |
| Hook | 30-minute deadline, `BeforeHookCreation`, no retries |

## Migration compatibility settings

These exist so an app can move onto the chart with zero rendered diff. After migration, each app
removes them one small PR at a time. Treat any that remain as documented one-offs.

| Setting | Effect |
|---|---|
| `fullName`, `containerName`, `role`, `serviceName`, `names.{pdb,vpa,scaledObject}` | Keep legacy names and selectors |
| `replicas.pinned` | Keep `spec.replicas` on a KEDA-managed Deployment |
| `compat.allowSingleReplica` | Allow 1 replica |
| `compat.bareContainerPort` | Unnamed container port; Service targets the port number |
| `pdb`, `vpa`, `probes`, `strategy`, `resources` set to `false` | Omit that default |
| `probes.{startup,readiness,liveness}` | Merge timing over a default probe, or `false` to drop it |
| `pdb: {minAvailable: N}` | Replace the default budget |
| `autoscaling.cooldownPeriod`, `autoscaling.pollingInterval`, `autoscaling.fallbackReplicas` | Reproduce existing KEDA settings |
| `autoscaling.behavior: false` | Drop the scale-down stabilization |
| CronJob `concurrencyPolicy`, `activeDeadlineSeconds`, history limits set to `false` | Omit that guardrail |
| Hook `activeDeadlineSeconds: false` | Omit the deadline |
