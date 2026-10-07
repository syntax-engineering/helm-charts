# Changelog

Each entry says what changes in rendered output for existing apps.

## [0.2.0] - 2026-10-06

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
