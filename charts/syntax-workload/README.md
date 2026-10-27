# syntax-workload

Declares Rails web apps, Sidekiq workers, cronjobs, and Argo CD deploy hooks with our standards built
in. Apps render it from their Kustomize overlays with `helmCharts:`.

## Using it

```yaml
# kubernetes/overlays/<env>/kustomization.yml
helmCharts:
  - name: syntax-workload
    repo: oci://ghcr.io/syntax-engineering/charts
    version: 0.4.0
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
| `Web` | `port`, `replicas`, `healthPath` (only for `probeType: http`, unless `probes: false`) | Deployment, Service, PDB, VPA, ScaledObject when autoscaling, and ingress objects when `ingress` is set |
| `Worker` | `replicas` | Deployment, PDB, VPA, ScaledObject when autoscaling |
| `CronJob` | `schedule`, `command` | CronJob |
| `Hook` | `phase` (`PreSync`, `Sync`, `PostSync`), `command` | Job with Argo CD hook annotations |

`replicas` is an integer, or `{min, max}` when `autoscaling` is set. The minimum is 2.

Every workload can set `command`, `args`, `env`, `envFrom`, `serviceAccount`, `nodeSelector`,
`priorityClassName` (`false` omits it), `resources`, `volumes`, `volumeMounts`, `selectorLabels`, and
`enabled: false`.

Web workloads can also set `probeType`, `portName`, `extraPorts`, and `serviceAnnotations`:

- `probeType` is `http` (the default, an `httpGet` on `healthPath`), `tcp` (a `tcpSocket` on the
  port), or `grpc` (the gRPC health check on the port number). The `probes` overrides only change
  timing. Adding a handler key (`httpGet`, `tcpSocket`, `grpc`) to an override renders two handlers,
  which Kubernetes rejects.
- `portName` names the container port, the Service port, and the Service `targetPort`. It defaults
  to `http`.
- `extraPorts` is a list of `{name, port}` added to the container and not exposed by the Service.
  Workers can set it too. CronJobs and Hooks cannot.
- `serviceAnnotations` is a map copied onto the Service.

`app` overrides the `app` label in a workload's selector and labels. It does not change the
`<app>-` name prefix. Set `role: false` to drop the `role` label from the selector.

`selectorLabels` adds labels to the workload's selector, pod labels, spread, PDB, and Service. Use it
when several workloads share a `role`. Selectors are immutable, so set it once. Deployments and
Services also carry their selector as `metadata.labels`.

Hooks ignore `selectorLabels` because their pods carry no labels. The render fails if one Web or
Worker workload's selector would also match another's pods, for example `role: worker` next to
`role: worker` with `selectorLabels`. The render also fails if a CronJob's pod labels would match a
Web or Worker selector. CronJobs may share a `role` with each other.

## Ingress

Web workloads can set `ingress`, a map of entries keyed by name. Each entry picks a `backend`, so one
workload can be public through NGINX Gateway Fabric and private through Tailscale at the same time.
Objects are named `<workload fullname>-<entry>`, for example `acme-web-public`. Set `name` on an entry
to use a different name, for example to keep the names an app already uses. Set `enabled: false` on an
entry to drop it.

```yaml
workloads:
  web:
    kind: Web
    port: 8080
    ingress:
      public:
        backend: ngf
        hostnames: [api.acme.example.com]
      grpc:
        backend: contour
        hostnames: [grpc.acme.example.com]
        protocol: h2c
        timeout: 20m
      tailnet:
        backend: tailscale
        hostname: acme-sprint-rails
```

Every backend routes all paths to the workload's Service on its `port`. Every entry can set
`annotations`, which are copied onto the route, HTTPProxy, or Ingress.

### Path rules

`ngf` and `contour` entries can send extra path prefixes to another Service with `paths`. Each rule
needs a `prefix`, a `service`, and a `port`. Everything else still goes to the workload's Service.

```yaml
    ingress:
      public:
        backend: ngf
        hostnames: [app.acme.example.com]
        paths:
          - { prefix: /assets, service: acme-assets-svc, port: 80 }
          - { prefix: /packs, service: acme-assets-svc, port: 80 }
```

The longest matching prefix wins, so the order of the rules does not matter. Each rule gets the entry's
`responseHeaders`, and on `contour` its `timeout`. `protocol` applies only to the workload's Service.
The Service must be in the app namespace.

### Renaming an entry

The entry key is part of the object names, so renaming an entry renames its objects. Kubernetes treats
a renamed object as a new one: it deletes the old object and creates the new one. What that means
depends on the backend:

| Backend | Named after the entry | Effect of renaming the entry |
|---|---|---|
| `ngf` | `HTTPRoute`s | The routes are replaced. The Gateway, Issuer, and Secret are named after the app, so the load balancer and certificate stay |
| `contour` | Issuer, `Certificate`, Secret, `HTTPProxy` | cert-manager issues a new certificate. This uses Let's Encrypt quota, and HTTPS may fail briefly while it issues |
| `tailscale` | `Ingress` | The operator creates a new tailnet device. While the old device still exists, the new one may get the name `<hostname>-1` |

To rename an entry without these effects, set `name` to the old object name, for example
`name: acme-web-grpc` after renaming `grpc` to `rpc`. The objects then keep their names. The render
fails if two entries with the same backend would use the same name.

### TLS certificates

Backends that terminate TLS with cert-manager (`ngf` and `contour`) issue certificates the same way. By
default each entry generates its own ACME `Issuer`, whose HTTP-01 solver the backend itself serves. This
works without any issuer in the app repo or on the cluster. Set `tls.clusterIssuer` to use a
ClusterIssuer instead; that issuer then needs a solver the backend can serve.

| Field | Default | Meaning |
|---|---|---|
| `tls.secretName` | per backend | Certificate Secret |
| `tls.clusterIssuer` | none | Use this ClusterIssuer instead of generating an Issuer |
| `tls.acme.email` | `devops@syntaxdata.com` | ACME account email for the generated Issuer |
| `tls.acme.server` | Let's Encrypt production | ACME directory URL for the generated Issuer |
| `tls.acme.waitInsteadOfSelfCheck` | none | Skip cert-manager's self-check and wait this long, for example `30s`. Needs cert-manager 1.21 or later. Use it where the self-check cannot reach the load balancer, such as behind PROXY protocol |

`tls.clusterIssuer` cannot be combined with `tls.acme`. The generated Issuer is named `<owner>-acme`
and keeps its ACME account key in `<owner>-acme-account`, where the owner is the Gateway for `ngf` and
the entry's objects for `contour`.

### `ngf`: NGINX Gateway Fabric

Generates an ACME `Issuer`, a Gateway, an HTTPS `HTTPRoute`, and an HTTP-to-HTTPS redirect `HTTPRoute`.

| Field | Default | Meaning |
|---|---|---|
| `hostnames` | required | Public hostnames; a leading `*.` is allowed |
| `tls.secretName` | `<app>-tls` | Certificate Secret, in the Gateway's namespace |
| `redirectHttp` | `true` | `false` drops the redirect route; the port 80 listeners stay for ACME HTTP-01 |
| `redirectStatusCode` | `301` | `301` or `308` |
| `responseHeaders` | none | Map of headers set on every response |
| `gateway.create` | `true` | `false` attaches the routes to an existing Gateway, and renders no Gateway or Issuer |
| `gateway.name` | `<app>-nginx-gateway` | Gateway name |
| `gateway.namespace` | `nginx-gateway` | Gateway namespace |
| `gateway.className` | `nginx` | GatewayClass |
| `gateway.annotations` | none | Extra Gateway annotations, for example `gateway.nginx.org/nginxproxy` |

The Gateway and Secret defaults match the names our apps already use. NGF creates a load balancer for
each Gateway, so keeping the name keeps the public IP when an app moves its Gateway onto the chart. The
render fails if two entries would create the same Gateway or write the same Secret; set `gateway.name`
or `tls.secretName` on one of them.

cert-manager issues the certificate from the Gateway's `cert-manager.io/issuer` annotation (or
`cert-manager.io/cluster-issuer` with `tls.clusterIssuer`). The generated Issuer lives next to the
Gateway, and its HTTP-01 solver attaches the challenge route to that Gateway through `parentRefs`. A
ClusterIssuer's `gatewayHTTPRoute` solver needs the same `parentRefs`, or the challenge route attaches
to nothing.

The Gateway gets an HTTP listener (`http-<host>`) and an HTTPS listener (`https-<host>`) for each
hostname. In the listener name, `.` becomes `-` and `*` becomes `wildcard`. A shared Gateway used with
`gateway.create: false` must name its listeners the same way.

The HTTPS listeners accept routes only from `namespace`. The HTTP listeners also accept routes from the
Gateway's namespace, where cert-manager creates the challenge route. Set `namespace` to the namespace
the app really runs in. A Kustomize patch that rewrites `metadata.namespace` after rendering does not
change the Gateway's route selector, so the Gateway would reject the routes.

### `contour`: Contour

Generates an ACME `Issuer`, a cert-manager `Certificate` for all hostnames, and one `HTTPProxy` per
hostname. With more than one hostname, each HTTPProxy name ends in `-<host>`.

Set `tls.perHost: true` to give each hostname its own Certificate and Secret instead, for example when
each domain belongs to a different customer. Each Certificate takes its HTTPProxy's name, and its Secret
defaults to that name plus `-tls`. `tls.secretNames` maps a hostname to a Secret name, so an app can keep
the Secrets it already has. The render fails if a `tls.secretNames` key is not in `hostnames`, or if two
hostnames would write the same Secret.

HTTPProxy has no cert-manager shim, so the chart renders the Certificate. The generated Issuer, in the
app namespace, solves HTTP-01 through an Ingress with the entry's `className` (default `contour`), which
the same Contour serves. With `tls.clusterIssuer`, the Certificate carries the label
`cert-manager.io/solver: contour`, so the ClusterIssuer can pick a Contour solver by label.

| Field | Default | Meaning |
|---|---|---|
| `hostnames` | required | Public hostnames |
| `tls.secretName` | `<workload fullname>-<entry>-tls`, or `<name>-tls` when `name` is set | Certificate Secret, in the app namespace |
| `tls.perHost` | `false` | One Certificate and Secret per hostname; cannot be combined with `tls.secretName` |
| `tls.secretNames` | none | Map of hostname to Secret name for `tls.perHost`; unlisted hostnames use the default |
| `protocol` | none | Upstream protocol: `h2c` for plaintext gRPC, or `h2` or `tls` |
| `timeout` | none | Response and idle timeout, for example `20m` |
| `responseHeaders` | none | Map of headers set on every response |
| `className` | none | `spec.ingressClassName` on the HTTPProxy, and the class of the ACME challenge Ingress (default `contour`) |
| `corsPolicy` | none | Contour [`CORSPolicy`](https://projectcontour.io/docs/main/config/api/#projectcontour.io/v1.CORSPolicy) on each virtualhost: `allowOrigin` and `allowMethods` (required), `allowHeaders`, `exposeHeaders`, `allowCredentials`, `allowPrivateNetwork`, `maxAge` |
| `loadBalancerPolicy` | none | Contour [`LoadBalancerPolicy`](https://projectcontour.io/docs/main/config/api/#projectcontour.io/v1.LoadBalancerPolicy) on the route: `strategy` (`Random`, `RoundRobin`, `WeightedLeastRequest`, `Cookie`, or `RequestHash`) and, for `RequestHash`, `requestHashPolicies` |

A gRPC-web service that browsers call from other origins sets `corsPolicy` per environment, usually with
only `allowOrigin` changing between environments:

```yaml
ingress:
  grpc:
    backend: contour
    hostnames: [grpc.staging.acme.example.com]
    protocol: h2c
    corsPolicy:
      allowCredentials: true
      allowOrigin: ["https://staging.acme.example.com"]
      allowMethods: [GET, POST, OPTIONS]
      allowHeaders: [authorization, content-type, x-grpc-web, x-user-agent, grpc-timeout]
      exposeHeaders: [grpc-status, grpc-message]
    loadBalancerPolicy: { strategy: WeightedLeastRequest }
```

### `tailscale`: Tailscale

Generates an `Ingress` with `ingressClassName: tailscale`. The Tailscale operator gives it a tailnet
address and a certificate.

| Field | Default | Meaning |
|---|---|---|
| `hostname` | required | Tailnet machine name, for example `acme-sprint-rails` |

Use `annotations` for operator options, such as `tailscale.com/funnel: "true"`.

## Defaults

| Setting | Default |
|---|---|
| Resources | requests 1000m / 2Gi, limits 2000m / 4Gi |
| VPA | recommendation-only, min 500m / 1Gi, max 4000m / 8Gi, `controlledValues: RequestsOnly` (set `vpa.controlledValues: RequestsAndLimits` on a Web or Worker workload to change it) |
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
| `fullName`, `containerName`, `role`, `app`, `serviceName`, `names.{pdb,vpa,scaledObject}` | Keep legacy names and selectors |
| `replicas.pinned` | Keep `spec.replicas` on a KEDA-managed Deployment |
| `compat.allowSingleReplica` | Allow 1 replica |
| `compat.bareContainerPort` | Unnamed container port; Service targets the port number |
| `compat.resizePolicy: false` | Omit the container `resizePolicy` |
| `compat.scaleTargetRef: full` | Add `apiVersion` and `kind` to the ScaledObject `scaleTargetRef` |
| `role: false` | Drop the `role` selector label |
| `pdb`, `vpa`, `probes`, `strategy`, `resources` set to `false` | Omit that default |
| `probes.{startup,readiness,liveness}` | Merge timing over a default probe, or `false` to drop it |
| `pdb: {minAvailable: N}` | Replace the default budget |
| `autoscaling.cooldownPeriod`, `autoscaling.pollingInterval`, `autoscaling.fallbackReplicas` | Reproduce existing KEDA settings |
| `autoscaling.behavior: false` | Drop the scale-down stabilization |
| CronJob `concurrencyPolicy`, `activeDeadlineSeconds`, history limits set to `false` | Omit that guardrail |
| Hook `activeDeadlineSeconds: false` | Omit the deadline |
