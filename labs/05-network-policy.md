# Lab 05 — Deny-All, and Why DNS Breaks First

**Time:** 30 minutes · **Prerequisites:** a cluster with a CNI that enforces NetworkPolicy

## Before you start: find out whether your CNI enforces policy

NetworkPolicy is an **API, not an implementation**. The API server happily
accepts the objects; whether anything enforces them is entirely up to the CNI.

| CNI | Enforces NetworkPolicy |
|---|---|
| Calico, Cilium, Antrea, Weave | yes |
| kind / kindnet | **version-dependent** — older kind enforced nothing; recent versions do |
| **flannel** | **no** |

When nothing enforces them you get the worst failure mode in Kubernetes
networking: the policies are accepted, `kubectl get netpol` lists them, and
**nothing happens**. You believe you are isolated and you are wide open.

Naming your CNI is not enough to know, so **measure it**. This two-pod test is
the only answer you should trust:

```bash
# 1. Deny everything in a scratch namespace
kubectl create namespace policy-test
kubectl label namespace policy-test kubernetes.io/metadata.name=policy-test --overwrite
kubectl apply -n policy-test -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
YAML

# 2. A pod in that namespace should now reach nothing at all
kubectl run probe -n policy-test --rm -it --restart=Never \
  --image=nicolaka/netshoot -- curl -sS --max-time 8 https://example.com

# Blocked  -> enforcement works.
# HTML back -> the policy is being ignored. Everything below will "pass"
#              while protecting nothing.
kubectl delete namespace policy-test
```

For reference, this repository's CI runs the same check on every build and
prints `NETWORKPOLICY ENFORCED` or `NETWORKPOLICY NOT ENFORCED`, because the
answer changes with kind versions and is not worth trusting to documentation.

If your cluster does **not** enforce policy and you want to work through the
rest of this lab, recreate it with the default CNI disabled and install
Calico:

```bash
kind delete cluster --name platform-lab
# uncomment `disableDefaultCNI: true` in clusters/kind/kind-cluster.yaml first
kind create cluster --config clusters/kind/kind-cluster.yaml

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/custom-resources.yaml
kubectl wait --for=condition=Ready pod --all -n calico-system --timeout=300s

./scripts/bootstrap-kind.sh
```

## 1. Prove you are currently wide open

```bash
kubectl run probe --rm -it --image=nicolaka/netshoot -n default --restart=Never -- \
  curl -s -o /dev/null -w 'from default namespace: %{http_code}\n' \
  --max-time 5 http://dev-checkout.checkout-dev.svc.cluster.local
```

`200`. A pod in an unrelated namespace reached the workload. Before any policy
exists, all traffic is allowed in both directions, cluster-wide.

## 2. Apply deny-all and watch DNS break

```bash
kubectl apply -n checkout-dev -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
YAML
```

Ingress is now blocked as intended:

```bash
kubectl run probe --rm -it --image=nicolaka/netshoot -n default --restart=Never -- \
  curl -s -o /dev/null -w 'from default: %{http_code}\n' --max-time 5 \
  http://dev-checkout.checkout-dev.svc.cluster.local
# 000 -- timed out. Good.
```

But now look at egress from inside the namespace:

```bash
kubectl run inside --rm -it --image=nicolaka/netshoot -n checkout-dev --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
# ;; connection timed out; no servers could be reached
```

**Every name lookup fails.** This is the single most common NetworkPolicy
mistake, and the symptom is deeply misleading: applications report
"connection refused", "host not found", "service unavailable" — all of which
look like a broken dependency rather than a firewall rule you wrote.

### Why

`podSelector: {}` with `policyTypes: [Egress]` denies **all** outbound traffic,
including UDP/53 to CoreDNS in `kube-system`. DNS is just another network
service, and nothing exempts it.

## 3. Fix it: allow DNS explicitly

```bash
kubectl apply -n checkout-dev -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
YAML

kubectl run inside --rm -it --image=nicolaka/netshoot -n checkout-dev --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
# resolves
```

Note **both** UDP and TCP. Resolvers fall back to TCP for responses larger than
512 bytes, so a UDP-only rule produces an intermittent failure that only shows
up for certain queries — far harder to diagnose than a total outage.

Note also that the two rules are **additive**. Policies never deny; they only
add allowances to whatever is already selected. `deny-all` is still in effect,
and `allow-dns` punches one hole in it.

## 4. Allow the ingress controller in

```bash
kubectl apply -n checkout-dev -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-controller
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
YAML

curl -s -o /dev/null -w 'via ingress: %{http_code}\n' \
  -H 'Host: checkout.localtest.me' http://localhost/healthz
# 200

kubectl run probe --rm -it --image=nicolaka/netshoot -n default --restart=Never -- \
  curl -s -o /dev/null -w 'from default: %{http_code}\n' --max-time 5 \
  http://dev-checkout.checkout-dev.svc.cluster.local
# 000 -- still blocked
```

Exactly the intended result: reachable through the front door, isolated from
everything else.

## 5. The repository's version

Everything above is already in the repo, with the same reasoning:

```bash
cat manifests/base/networkpolicy.yaml
```

## Gotchas worth knowing

- **`namespaceSelector` + `podSelector` in one `from` entry is an AND** (that
  pod, in that namespace). As two separate list entries it is an OR. The
  indentation is the only difference, and it silently changes the meaning.
- **Policies are additive and never deny.** You cannot write "allow everything
  except X."
- **Egress rules match the pod IP, not the Service IP.** Allowing a Service's
  ClusterIP does not work; select the backing pods.
- **A policy only affects pods it selects.** A pod no policy selects stays
  wide open, which is why the deny-all with `podSelector: {}` comes first.

## Cleanup

```bash
kubectl delete netpol --all -n checkout-dev
kubectl apply -k manifests/overlays/dev
```
