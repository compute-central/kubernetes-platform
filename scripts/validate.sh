#!/usr/bin/env bash
# Everything CI runs, runnable locally. No cluster required.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

K8S_VERSION="${K8S_VERSION:-1.31.0}"
FAILED=0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAILED: %s\033[0m\n' "$1"; FAILED=1; }

if ! command -v kubeconform >/dev/null 2>&1; then
  cat >&2 <<'MSG'
kubeconform is not installed. It validates manifests against the Kubernetes
JSON schemas offline, with no cluster:

  brew install kubeconform
  # or: go install github.com/yannh/kubeconform/cmd/kubeconform@latest

MSG
  exit 1
fi

step "Building every kustomize overlay"
for overlay in manifests/base manifests/overlays/*; do
  [ -f "${overlay}/kustomization.yaml" ] || continue
  printf '    %-34s' "${overlay}"
  if kubectl kustomize "${overlay}" >/dev/null 2>&1; then echo "built"; else echo; fail "${overlay} does not build"; fi
done

step "Validating overlays against Kubernetes ${K8S_VERSION} schemas"
for overlay in manifests/base manifests/overlays/*; do
  [ -f "${overlay}/kustomization.yaml" ] || continue
  printf '    %-34s' "${overlay}"
  if kubectl kustomize "${overlay}" | kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}" - ; then :; else fail "${overlay} has invalid resources"; fi
done

step "Linting the Helm chart with every values file"
helm lint charts/webapp || fail "helm lint (defaults)"
for values in charts/webapp/values-*.yaml; do
  printf '    %s\n' "${values}"
  helm lint charts/webapp -f "${values}" >/dev/null || fail "helm lint ${values}"
done

step "Validating rendered Helm output"
printf '    %-34s' "defaults"
helm template checkout charts/webapp | kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}" - || fail "render defaults"
for values in charts/webapp/values-*.yaml; do
  printf '    %-34s' "$(basename "${values}")"
  helm template checkout charts/webapp -f "${values}" \
    | kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}" - || fail "render ${values}"
done

step "Checking the policy and gitops manifests"
kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}" \
  -ignore-missing-schemas policies/ || fail "policies/"

if [ "${FAILED}" -eq 0 ]; then
  printf '\n\033[32mAll checks passed.\033[0m\n'
else
  printf '\n\033[31mSome checks failed.\033[0m\n'
  exit 1
fi
