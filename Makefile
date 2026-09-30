CHART := charts/syntax-workload

.PHONY: test lint unit schema parity policy
test: lint unit schema parity policy

lint:
	for f in $(CHART)/tests/schema/good/*.yaml; do helm lint $(CHART) -f $$f || exit 1; done

unit:
	helm unittest $(CHART)

schema:
	scripts/test-schema.sh

parity:
	scripts/test-parity.sh

policy:
	scripts/test-policy.sh
