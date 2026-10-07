chart := "charts/syntax-workload"

# List the available recipes.
default:
    @just --list

# Run every check CI runs.
test: lint unit parity policy

# Lint the chart against each valid values fixture.
lint:
    for f in {{chart}}/tests/schema/good/*.yaml; do helm lint {{chart}} -f "$f" || exit 1; done

# Run the helm-unittest suites, including the values schema cases.
unit:
    helm unittest {{chart}}

# Check the chart still reproduces terra, lexicon, and syntax-direct.
parity:
    scripts/test-parity.rb

# Check the standard fixture and bad.yaml against the Kyverno policies' declared results.
policy:
    helm template standard {{chart}} -f {{chart}}/tests/values/standard.yaml > policies/tests/standard/rendered.yaml
    kyverno test policies/tests/standard --require-tests
