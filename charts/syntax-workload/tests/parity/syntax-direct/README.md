This fixture is syntax-direct's rebuild overlay at commit `30b775385`, limited to the workloads the chart renders. `expected/` is that overlay's output plus the accepted migration diff:

- Drop `imagePullPolicy: IfNotPresent`, the pod `restartPolicy: Always`, and mcp's empty `args: []`.
- The index portal gets `namespace: syntax-direct-rebuild` and `app` labels on its Deployment and Service, the pull secret `syntax-direct-registry-secret`, a named `http` container port, and a Service port named `http` that targets it. The Service port changes from 80 to 3000, so the portal's ingress must switch to `port.name: http`. Its image is the placeholder `ghcr.io/locusanalytics/index_portal_rebuild:placeholder`.
- The portal's tcp probes use `port: http` (the named container port), and its readiness probe gains `successThreshold: 1`, the Kubernetes default.
- The portal PDB gets `namespace: syntax-direct-rebuild` but no `app` label, because the chart renders no PDB labels.
