# Changelog

Each entry says what changes in rendered output for existing apps.

## [0.5.0] - 2026-11-05

No rendered-output change for values that do not use `ingress`. This release reshapes the 0.4.0 `ngf`
ingress API, and values that use the removed fields must be migrated:
- `gateway.annotations`, `gateway.name`, `gateway.namespace`, and `gateway.className` on an `ngf` entry
  move to `ingresses.ngf.gateways.<key>.annotations`, `.name`, `.namespace`, and `.className`.
- `tls.*` on an `ngf` entry moves to `ingresses.ngf.gateways.<key>.tls`.
- `gateway.create: false` becomes `gateway: <key>` naming a shared Gateway declared under
  `ingresses.ngf.gateways`, or an external Gateway there (`create: false`, `name`, `namespace`,
  `listeners`).

A 0.4.0 values file that sets the `gateway.*` object form or `tls.*` on an `ngf` entry now fails the
schema. `contour` entries keep `tls`.

Added (all optional):
- `ingresses.ngf.gateways`, a map of Gateways keyed by name, which `ngf` entries pick with a new
  `gateway: <key>` field (default `default`). `default` is implicit: an enabled `ngf` entry that names
  it gets a Gateway rendered with the defaults when it is not declared, named `<app>-nginx-gateway`
  with the Secret `<app>-tls` and the Issuer `<app>-nginx-gateway-acme`, the same names 0.4.0 used. Other
  keys must be declared and default to `<app>-<key>-gateway` and `<app>-<key>-tls`.
  Per Gateway: `name`, `namespace`, `className`, `annotations`, `tls` (`secretName`, `clusterIssuer`,
  `acme`), `create`, and `listeners.http`/`listeners.https`.
- A created Gateway renders once, with one Issuer and one Secret, labeled `app` only (no `role`), and gets listeners for the hostnames
  of every enabled `ngf` entry that names it, across all workloads. With `create: false` the Gateway,
  Issuer, and Secret are not rendered; routes attach to the named `listeners` through
  `parentRefs.sectionName`.
- The render fails when two enabled `ngf` entries on the same Gateway list the same hostname, since both
  routes would claim `/` and the oldest would win. Entries on different Gateways may share one.
- The render fails for an entry that names an undeclared Gateway, for two created Gateways that would
  render the same Gateway or write the same Secret in one namespace. The schema rejects an external
  Gateway without `name`, `namespace`, or `listeners`, and `tls`, `className`, or `annotations` on it.
  Unknown keys under `ingresses` and `ingresses.ngf` are rejected too.
- `paths` items on `ngf` entries take `match: Exact` and `rewrite: { fullPath: / }`, which render an
  `Exact` path match and a `URLRewrite` filter with `ReplaceFullPath`.
- `service` and `port` on `paths` items default to the workload's own Service and port. They must be
  set together. This also applies to `contour` entries, which do not take `match` or `rewrite`.

Removed from `ngf` entries (the schema rejects them): the `gateway` object form (`create`, `name`,
`namespace`, `className`, `annotations`) and `tls`. Move them to `ingresses.ngf.gateways.<key>`.
`contour` entries keep `tls` unchanged.

## [0.4.0] - 2026-10-27

No rendered-output change for existing values.

Added (all optional):
- `ingress` on Web workloads: a map of named entries, each with a `backend`.
  - `ngf`: a Gateway with HTTP and HTTPS listeners per hostname, an HTTPS `HTTPRoute`, and an
    HTTP-to-HTTPS redirect route. The Gateway is named `<app>-nginx-gateway` and uses Secret
    `<app>-tls` by default, matching existing apps. An ACME `Issuer` next to the Gateway issues the
    certificate, with its HTTP-01 solver attached to that Gateway; `tls.clusterIssuer` uses a
    ClusterIssuer instead. `gateway.create: false` attaches the routes to an existing Gateway.
    `timeout` sets proxy read and send timeouts through a `ProxySettingsPolicy` on the HTTPS route
    (NGF 2.6 or later).
  - `contour`: an ACME `Issuer` that solves HTTP-01 through a Contour Ingress, a cert-manager
    `Certificate`, and one `HTTPProxy` per hostname, with optional `protocol`, `timeout`, and
    `className`. `tls.clusterIssuer` uses a ClusterIssuer instead. `tls.perHost: true` renders a
    Certificate and Secret per hostname, with optional `tls.secretNames` to name each Secret.
    `corsPolicy` sets CORS on each HTTPProxy's virtualhost (for example, gRPC-web origins per
    environment), and `loadBalancerPolicy` sets how Contour picks an endpoint on the route. Both
    use Contour's field names.
  - `ngf` and `contour` share `tls.acme.{email,server,waitInsteadOfSelfCheck}` for the generated
    Issuer.
  - `ngf` and `contour` take `paths: [{prefix, service, port}]`, which sends extra path prefixes
    to another Service: extra `HTTPRoute` rules or `HTTPProxy` routes. `/` still goes to the
    workload's Service.
  - `ngf` entries can set `snippets` (a map of NGINX context to config) and `clientSettings` (request
    body and keep-alive limits). They render a `SnippetsFilter` on the HTTPS route and a
    `ClientSettingsPolicy` that targets it.
  - `tailscale`: an `Ingress` with `ingressClassName: tailscale` on the workload's Service port.
  - `name` on any entry replaces the `<fullname>-<entry>` object name, so an entry can be renamed
    without replacing its objects. The render fails if two entries with the same backend would use
    the same name.

## [0.3.0] - 2026-10-07

No rendered-output change for existing values.

Added (all optional):
- `probeType: http | tcp | grpc` on Web workloads; `healthPath` is required only for `http`.
- `portName`: names the container port, the Service port, and its `targetPort` (default `http`).
- `extraPorts: [{name, port}]` on Web and Worker containers; not exposed by the Service.
- `serviceAnnotations` on Web Services.
- `compat.resizePolicy: false` and `compat.scaleTargetRef: full` for migration parity.
- `vpa.controlledValues` (default `RequestsOnly`).
- Per-workload `app`, and `role: false` to drop the `role` selector label.

## [0.2.0] - 2026-10-07

Rendered-output change for existing values: Deployments and Services get `metadata.labels` equal to
their selector. Nothing else changes for existing values.

Added (all optional):
- `selectorLabels` per workload: extra selector labels merged into `{app, role}`. `app` and `role`
  are rejected as keys.
- `priorityClassName`, app-wide and per workload; `false` on a workload omits it.
- `volumes` and `volumeMounts` per workload, passed through unchanged.

Fixed:
- The uniqueness check compares the full selector, so workloads can share a `role` when their
  `selectorLabels` differ. CronJobs may share a role with each other, but a CronJob whose pod labels
  would match a Web or Worker selector still fails the render. One Web or Worker selector that
  matches another's pods (a subset, not just an exact match) now fails too.

## [0.1.0] - 2026-10-06

First release. Kinds: Web, Worker, CronJob, Hook. No existing apps use the chart yet, so there is no
rendered-output change to anyone.
