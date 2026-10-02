#!/usr/bin/env bash
# Create a local cluster with an ingress controller and metrics-server, then
# deploy the dev overlay. Everything this repository demonstrates works
# afterwards except NetworkPolicy enforcement, which needs a CNI that
# implements it (see labs/05).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CLUSTER="${CLUSTER:-platform-lab}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required but not installed." >&2; exit 1; }; }
need kind
need kubectl
need helm

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "==> Cluster ${CLUSTER} already exists; reusing it"
else
  echo "==> Creating cluster ${CLUSTER}"
  kind create cluster --config clusters/kind/kind-cluster.yaml --wait 120s
fi

kubectl config use-context "kind-${CLUSTER}"

echo "==> Installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# The namespace label the NetworkPolicies select on. Kubernetes sets
# kubernetes.io/metadata.name automatically, but being explicit here makes the
# dependency visible.
kubectl label namespace ingress-nginx kubernetes.io/metadata.name=ingress-nginx --overwrite

echo "==> Waiting for the ingress controller to be ready"
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "==> Installing metrics-server (the HPA cannot scale without it)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait --timeout 180s
# --kubelet-insecure-tls is required on kind, whose kubelet serving
# certificates are self-signed. Never use it on a real cluster.

echo "==> Deploying the dev overlay"
kubectl apply -k manifests/overlays/dev
kubectl rollout status deployment/dev-checkout -n checkout-dev --timeout=180s

cat <<'NEXT'

Cluster is up.

  kubectl get pods -A
  curl -H 'Host: checkout.localtest.me' http://localhost/healthz

Try the labs:

  labs/01-first-deployment.md     what a Deployment actually does
  labs/02-rolling-update.md       zero-dropped-request rollouts
  labs/03-probes-and-failure.md   why conflating probes causes outages
  labs/04-resources-and-oom.md    requests, limits, QoS and eviction
  labs/05-network-policy.md       deny-by-default, and why DNS breaks first

Tear it down:

  kind delete cluster --name platform-lab

NEXT
