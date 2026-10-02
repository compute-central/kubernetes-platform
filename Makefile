# Kubernetes platform tasks. `make validate` is exactly what CI runs and needs
# no cluster.
.DEFAULT_GOAL := help
SHELL := /bin/bash
OVERLAY ?= dev
NS      ?= checkout-$(OVERLAY)
K8S_VERSION ?= 1.31.0

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: validate
validate: ## Build and schema-validate everything (no cluster needed)
	./scripts/validate.sh

.PHONY: build
build: ## Render one overlay to stdout (OVERLAY=production)
	kubectl kustomize manifests/overlays/$(OVERLAY)

.PHONY: diff
diff: ## Show what applying an overlay would change in the cluster
	kubectl diff -k manifests/overlays/$(OVERLAY) || true

.PHONY: cluster
cluster: ## Create the kind cluster with ingress and metrics-server
	./scripts/bootstrap-kind.sh

.PHONY: deploy
deploy: ## Apply an overlay and wait for the rollout
	kubectl apply -k manifests/overlays/$(OVERLAY)
	kubectl rollout status deployment -n $(NS) --timeout=180s

.PHONY: helm-install
helm-install: ## Install the chart with the matching values file
	helm upgrade --install checkout charts/webapp \
		--namespace $(NS) --create-namespace \
		-f charts/webapp/values-$(OVERLAY).yaml --wait --timeout 180s

.PHONY: helm-test
helm-test: ## Run the chart's helm test hook
	helm test checkout --namespace $(NS) --logs

.PHONY: helm-render
helm-render: ## Render the chart with the matching values file
	helm template checkout charts/webapp -f charts/webapp/values-$(OVERLAY).yaml

.PHONY: gitops
gitops: ## Apply the Argo CD project and Applications
	kubectl apply -k gitops

.PHONY: status
status: ## Show what is running
	@kubectl get deploy,rs,pod,svc,ingress,hpa,pdb -n $(NS) 2>/dev/null || true
	@echo
	@kubectl get pod -n $(NS) \
		-o custom-columns='NAME:.metadata.name,QOS:.status.qosClass,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName' 2>/dev/null || true

.PHONY: logs
logs: ## Tail logs from every replica
	kubectl logs -n $(NS) -l app.kubernetes.io/name=checkout --tail=50 -f --max-log-requests=10

.PHONY: events
events: ## Show recent events, oldest first
	kubectl get events -n $(NS) --sort-by=.lastTimestamp

.PHONY: clean
clean: ## Delete the deployed overlay
	kubectl delete -k manifests/overlays/$(OVERLAY) --ignore-not-found

.PHONY: destroy
destroy: ## Delete the kind cluster entirely
	kind delete cluster --name platform-lab
