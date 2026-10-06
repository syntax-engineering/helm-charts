# Kyverno CLI 1.19: `kyverno test` with ValidatingPolicy

> **Status (2026-09-30):** adopted. The test file and `bad.yaml` live in `policies/tests/standard/`, and `just policy` renders the fixture and runs `kyverno test`. Two parts of this note differ from what the repo does:
> - The repo does not check that every rendered workload has a declared result.
> - The Deployment PDB/VPA pairing is covered by `charts/syntax-workload/tests/standard_pairing_test.yaml` (helm-unittest), not by `cross-check.sh`.
>
> The `resources: []` quirk under Caveats still applies.

Date: 2026-09-30. Kyverno CLI 1.19.1 (commit 40ec788d) run via mise from the repo root. Source references are to the `release-1.19` branch of https://github.com/kyverno/kyverno (shallow clone, HEAD 29cdac47), paths under `cmd/cli/kubectl-kyverno/`.

## Answer

Yes. `kyverno test` in 1.19 supports `policies.kyverno.io/v1` `ValidatingPolicy` directly: the test file is `apiVersion: cli.kyverno.io/v1alpha1`, `kind: Test`, with `policies`, `resources` and `results`. A ValidatingPolicy has no rules, so each result names only `policy`, `kind` and `result` (`pass` or `fail`); `rule` and `isValidatingPolicy` are not needed. Results are compared against the engine's real output, and any mismatch prints `Want <x>, got <y>` and exits 1, so the summary-text parsing in `scripts/test-policy.sh` can go. Three behaviours need care: (1) `kyverno test` reads resources from disk, so a `helm template` step must write the rendered file first; (2) a multi-document file is split into individual resources, and a result with no resource filter is checked against every resource in the file (non-matching ones show `Fail / Not found`), so each result must name its resources; (3) `resourceSpecs` (the only way to tell Deployment `acme-web` from Service `acme-web`) is honored only when `resources` is also present, so `resources: []` is needed next to it. A negative case is a committed `bad.yaml` with results declared `fail`. All of this was verified by real runs (below). The cross-object PDB/VPA rule can be expressed offline with `resource.List` plus a `context:` file, but it is a separate mechanism (see the last Evidence item).

## Evidence

### Source (kyverno/kyverno, branch release-1.19)

1. Test schema. `apis/v1alpha1/test.go`, type `Test`: fields `policies`, `resources`, `results`, `variables`, `context`, `clusterResources`, `exceptions`, `values`, among others. Test results: `apis/v1alpha1/test_result.go` lines 6-82 (`TestResultBase`: `policy`, `rule` optional, `isValidatingPolicy` optional, `result`, `kind`, `operation`) and lines 85-95 (`TestResultData`: `resources`, `resourceSpecs`). Upstream example: `test/cli/test/cel-http-get-mock/kyverno-test.yaml` uses `apiVersion: cli.kyverno.io/v1alpha1`, `kind: Test`.
2. No rule name for ValidatingPolicy. `commands/test/command.go` lines 294-306: `isRulelessPolicyKind` returns true for `ValidatingPolicy`, `NamespacedValidatingPolicy`, `ValidatingAdmissionPolicy`, and the other CEL policy kinds. `commands/test/output.go` line 105: `if test.Rule == "" || isRulelessPolicyKind(...)` checks all rule responses of the policy instead of looking up `test.Rule`. So `rule:` is optional and ignored for ValidatingPolicy.
3. `isValidatingPolicy` has no effect in 1.19. `grep -rn IsValidatingPolicy` over non-test Go files finds only the field definition (`test_result.go:27`). Upstream examples set it to `true`, but omitting it works (my run below omits it).
4. Result matching. `commands/test/output.go` line 39: `if test.Resources != nil { ... }` builds the filtered resource list; lines 40-56 match a name (`name`) or `namespace/name` only (no kind), and lines 58-80 (`resourceSpecs`, matching group/version/namespace/name, and not `kind`) sit INSIDE that same `if`. If `resources` is absent, the list is empty and lines 82-92 check every resource. Policy match is by name at line 98 (`response.Policy().GetName() != polNameNs[...]`).
5. Comparison and exit code. `commands/test/command.go` lines 272-281: `compareExpectedRuleResult` returns `Want %s, got %s` on a mismatch; `command.go:195` (`rc.Fail > 0`) returns `fmt.Errorf("%d tests failed")`, which the CLI turns into exit 1.
6. `--require-tests`. `command.go` lines 53, 114 and 126-127: with no `kyverno-test.yaml` found, the command prints "No test yamls available" and exits 0 unless `--require-tests` is set (then `no tests found`, exit 1).
7. Offline context for cross-object lookups. `apis/v1alpha1/context.go`: `Context` kind (`spec.resources`, `spec.images`); `processor/utils.go` lines 26-80 load `context:` resources into a `FakeContextProvider` that backs CEL `resource.List` / `resource.Get` when the test has no cluster.
8. Docs. https://kyverno.io/docs/kyverno-cli/usage/test/ documents `kyverno test` generally; the ValidatingPolicy page https://kyverno.io/docs/policy-types/validating-policy/ only says "Testing: Kyverno CLI (unit)". The field-level behaviour above comes from source, not from the docs site.

### Empirical runs (1.19.1)

Setup, all under `$TMPDIR/kt` (contents copied from the repo, nothing in the repo modified):

```
kt/policies/workload-standards.yaml      (copy of policies/workload-standards.yaml)
kt/standard/rendered.yaml                (helm template output, 15 objects)
kt/standard/bad.yaml                     (Deployment bad-web + CronJob bad-cron)
kt/standard/kyverno-test.yaml            (below)
```

Note: `mise exec` failed mid-session with "Failed to install aqua:casey/just@1.52.0" because `mise.toml` in the working tree was being edited by something else (the tree has uncommitted justfile work; I did not touch it). The later runs call the mise-installed binary directly: `/Users/zachhall/.local/share/mise/installs/kyverno/1.19.1/kyverno` (same 1.19.1).

Commands and results:

```
MISE_TRUSTED_CONFIG_PATHS=$PWD mise exec -- helm template standard charts/syntax-workload -f charts/syntax-workload/tests/values/standard.yaml > $TMPDIR/kt/standard/rendered.yaml
MISE_TRUSTED_CONFIG_PATHS=$PWD mise exec -- kyverno apply policies/ --resource $TMPDIR/kt/standard/rendered.yaml
  -> pass: 15, fail: 0, warn: 0, error: 0, skip: 0          (today's behaviour)
kyverno apply $TMPDIR/kt/policies --resource $TMPDIR/kt/standard/bad.yaml
  -> 6 failures: container-requests, serving-probes, hostname-spread, two-replicas on bad-web; container-requests, cron-guardrails on bad-cron
```

| Run | Result |
| --- | --- |
| Results with only `policy/kind/result`, no `resources` | Each result is checked against all 15 resources; 55 passed, 50 failed ("Fail / Not found" for resources a policy does not match), exit 1. Proves resources must be named per result. |
| `resources: [acme-web, ...]` (names only) | 17 passed, 6 failed: Services named `acme-web` and `acme-mcp` collide with the Deployments of the same name (name-only matching). |
| `resourceSpecs` without `resources` | Filter ignored (138 failed), matching source item 4. |
| `resources: []` plus `resourceSpecs` (the proposed file) | `Test Summary: 21 tests passed and 0 tests failed`, exit 0. Includes the six `fail` expectations on bad.yaml, reported as `Pass / Ok`. |
| Declare `bad-web` / `container-requests` as `pass` (wrong on purpose) | `Fail / Want pass, got fail`, `Test Summary: 0 tests passed and 1 tests failed`, `Error: 1 tests failed`, exit 1. |
| Result names a policy that does not exist | `Fail / Not found`, exit 1. |
| Only one result declared, other resources in the file | Exit 0; the undeclared resources are simply not checked. |
| Empty dir, `kyverno test dir` / `--require-tests` | `No test yamls available`, exit 0 / `Error: no tests found`, exit 1. |
| `policies:` given as an absolute path | Works (exit 0); `../policies/...` relative path works too. |

Cross-object experiment (`$TMPDIR/kt/xobj`): a ValidatingPolicy using `variables: [{name: pdbs, expression: resource.List("policy/v1","poddisruptionbudgets",object.metadata.namespace)}]` and the validation `dyn(variables.pdbs).items.exists(p, p.spec.selector.matchLabels == object.spec.selector.matchLabels)`, a `context: ctx.yaml` file (`kind: Context`) holding one PodDisruptionBudget, and two Deployments. Result: the Deployment with a PDB passes, the one without fails, both as declared (exit 0). Flipping the `lonely` expectation gave `Want pass, got fail`, exit 1. Without `dyn(...)` compilation fails ("expression of type 'any' cannot be range of a comprehension"). The VPA half was not tried: VerticalPodAutoscaler is a CRD, so it would need a `clusterResources` file with the CRD for the REST mapper (`commands/test/test.go` lines 255-275 load it), which I did not verify.

## Proposed kyverno-test.yaml for this repo

Verified as written, in this layout (exit 0, 21 passed). `rendered.yaml` is produced by `helm template` just before the run; `bad.yaml` is a committed fixture. In the repo I would place these under something like `policies/tests/standard/` and change the policy path to `../../workload-standards.yaml` (an equivalent relative path, not separately run; the `../policies/...` form and an absolute path were both run).

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: workload-standards
policies:
  - ../policies/workload-standards.yaml
resources:
  - rendered.yaml
  - bad.yaml
results:
  - policy: container-requests
    kind: Deployment
    result: pass
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-web }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-mcp }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-sidekiq }
  - policy: container-requests
    kind: CronJob
    result: pass
    resources: []
    resourceSpecs:
      - { group: batch, version: v1, kind: CronJob, namespace: acme-env, name: acme-nightly }
  - policy: container-requests
    kind: Job
    result: pass
    resources: []
    resourceSpecs:
      - { group: batch, version: v1, kind: Job, namespace: acme-env, name: acme-migrate-db }
  - policy: serving-probes
    kind: Deployment
    result: pass
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-web }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-mcp }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-sidekiq }
  - policy: hostname-spread
    kind: Deployment
    result: pass
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-web }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-mcp }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-sidekiq }
  - policy: two-replicas
    kind: Deployment
    result: pass
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-web }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-mcp }
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: acme-sidekiq }
  - policy: cron-guardrails
    kind: CronJob
    result: pass
    resources: []
    resourceSpecs:
      - { group: batch, version: v1, kind: CronJob, namespace: acme-env, name: acme-nightly }
  - policy: container-requests
    kind: Deployment
    result: fail
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: bad-web }
  - policy: container-requests
    kind: CronJob
    result: fail
    resources: []
    resourceSpecs:
      - { group: batch, version: v1, kind: CronJob, namespace: acme-env, name: bad-cron }
  - policy: serving-probes
    kind: Deployment
    result: fail
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: bad-web }
  - policy: hostname-spread
    kind: Deployment
    result: fail
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: bad-web }
  - policy: two-replicas
    kind: Deployment
    result: fail
    resources: []
    resourceSpecs:
      - { group: apps, version: v1, kind: Deployment, namespace: acme-env, name: bad-web }
  - policy: cron-guardrails
    kind: CronJob
    result: fail
    resources: []
    resourceSpecs:
      - { group: batch, version: v1, kind: CronJob, namespace: acme-env, name: bad-cron }
```

`bad.yaml` (verified fixture):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: bad-web, namespace: acme-env }
spec:
  replicas: 1
  selector: { matchLabels: { app: bad } }
  template:
    metadata: { labels: { app: bad } }
    spec:
      containers:
        - name: app
          image: example/bad:1
          ports: [{ containerPort: 80 }]
---
apiVersion: batch/v1
kind: CronJob
metadata: { name: bad-cron, namespace: acme-env }
spec:
  schedule: "0 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers: [{ name: c, image: example/bad:1 }]
```

## How the `policy` recipe would change

Today (`justfile` line 23 and the Makefile target): `policy: scripts/test-policy.sh`, which renders, runs `kyverno apply`, greps the `pass: N, fail: 0` line, then runs `scripts/cross-check.sh`.

Proposed recipe (not run as a recipe; each command was run by hand above):

```just
# Check the standard fixture and the negative fixtures against the Kyverno policies.
policy:
    helm template standard {{chart}} -f {{chart}}/tests/values/standard.yaml > policies/tests/standard/rendered.yaml
    kyverno test policies/tests/standard --require-tests
    scripts/cross-check.sh policies/tests/standard/rendered.yaml
```

Then `scripts/test-policy.sh` shrinks to the two helm/cross-check lines or is removed, and `rendered.yaml` goes in `.gitignore`. The summary regex, the `pass >= 1` check and the `|| true` are gone: `kyverno test` exits non-zero on any mismatch. `--require-tests` guards against the test file being missing or misnamed.

## Caveats and open questions

- Silent gaps: a resource in `rendered.yaml` that has no declared result is not checked (verified). If the chart starts rendering a new Deployment, the test will not notice. Mitigations: keep `kyverno apply` (or the existing summary check) as a second guard, or add a small script assertion that every Deployment/CronJob/Job name appears in the test file.
- The pass expectations list resource names from the fixture (`acme-web`, `acme-mcp`, `acme-sidekiq`, `acme-nightly`, `acme-migrate-db`). Renaming `app` in `standard.yaml` means editing the test file.
- `resources: []` next to `resourceSpecs` relies on behaviour in `output.go` (non-nil empty slice), not on documented semantics. It works in 1.19.1 but could change; the alternative, names only, collides with Services of the same name.
- Field names come from the 1.19 branch head and the 1.19.1 binary; I did not diff against the exact 1.19.1 tag. I did not find a 1.19 CHANGELOG entry for these fields, so no release-note claim is made.
- The `Result` column in the table means "expectation met", not "policy passed"; a declared `fail` that really fails prints `Pass / Ok`.
- Cross-check: the PDB half works offline via `resource.List` and a `context:` file, but the context file must contain the rendered PDBs/VPAs, so it would have to be generated from `rendered.yaml` (for example with yq), which I did not build. The VPA half needs a CRD via `clusterResources`. Given that, `scripts/cross-check.sh` is simpler and I would keep it unless you want everything in one tool.
- The working tree had uncommitted changes from another process (justfile, mise.toml) during this research; none came from me, and nothing tracked was modified by this work.
