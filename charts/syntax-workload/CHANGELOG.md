# Changelog

Each entry says what changes in rendered output for existing apps.

## [0.4.0] - 2026-10-27

No rendered-output change for existing values.

Added (all optional):
- `ingress` on Web workloads: a map of named entries, each with a `backend`.
  - `ngf`: a Gateway with HTTP and HTTPS listeners per hostname, an HTTPS `HTTPRoute`, and an
    HTTP-to-HTTPS redirect route. The Gateway is named `<app>-nginx-gateway` and uses Secret
    `<app>-tls` by default, matching existing apps. An ACME `Issuer` next to the Gateway issues the
    certificate, with its HTTP-01 solver attached to that Gateway; `tls.clusterIssuer` uses a
    ClusterIssuer instead. `gateway.create: false` attaches the routes to an existing Gateway.
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
