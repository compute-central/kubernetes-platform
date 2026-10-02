# Kubernetes Platform

[![CI](https://github.com/compute-central/kubernetes-platform/actions/workflows/ci.yml/badge.svg)](https://github.com/compute-central/kubernetes-platform/actions/workflows/ci.yml)
[![Kubernetes 1.29+](https://img.shields.io/badge/kubernetes-1.29%2B-326ce5.svg)](https://kubernetes.io/)
[![Helm 3](https://img.shields.io/badge/helm-3.x-0f1689.svg)](https://helm.sh/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Production-shaped Kubernetes manifests, a Helm chart, GitOps wiring, and five
labs that each break something on purpose.

It is the reference implementation for the
**[Kubernetes track](https://computecentral.in/kubernetes/)** on
[Compute Central](https://computecentral.in/). Every manifest is validated
against the real Kubernetes JSON schemas in CI, and then deployed to an actual
kind cluster — because schema validation cannot catch a probe pointed at the
wrong path or a selector that matches nothing.

## Quick Start

```bash
git clone https://github.com/compute-central/kubernetes-platform.git
cd kubernetes-platform

make validate   # builds and schema-validates everything, no cluster needed
make cluster    # kind + ingress-nginx + metrics-server + the dev overlay
make status

curl -H 'Host: checkout.localtest.me' http://localhost/healthz
```

Then work through the [labs](labs/).

## Layout

```
manifests/
├── base/                  complete and deployable on its own
│   ├── deployment.yaml      probes, security context, topology spread, preStop
│   ├── networkpolicy.yaml   deny-all + the DNS rule everyone forgets
│   ├── rbac.yaml            a Role scoped to one named ConfigMap
│   ├── hpa.yaml pdb.yaml service.yaml ingress.yaml
│   ├── checkout-config.env  generated into a ConfigMap, so changes roll pods
│   └── nginx/default.conf   serves /healthz, which the probes depend on
└── overlays/
    ├── dev/         1 replica, no HPA, no PDB — single-node friendly
    ├── staging/     2 replicas, debug logging
    └── production/  6 replicas, digest-pinned image, quota, strict spread

charts/webapp/        the same workload as a Helm chart
├── templates/        including a `helm test` hook that curls the Service
├── values.yaml       secure defaults; environments override, not opt in
└── values-dev.yaml values-production.yaml

policies/             ResourceQuota, LimitRange, Pod Security Admission labels
gitops/               Argo CD AppProject + Applications (app-of-apps)
clusters/kind/        a 3-node local cluster that can exercise all of it
labs/                 five labs, each one breaks something deliberately
scripts/              bootstrap-kind.sh, validate.sh
```

## Ideas Worth Stealing

Short version of why the manifests look the way they do. Each one is a specific
production failure.

**Three probes, three different jobs.** `startupProbe` answers "has it
booted?", `livenessProbe` answers "is it wedged?", `readinessProbe` answers
"should it get traffic?". A liveness probe that checks a *dependency* is the
most common self-inflicted Kubernetes outage: the dependency blips, every
replica's probe fails at once, every replica restarts at once, and a
degradation becomes a total outage with a reconnection storm on top.
[Lab 03](labs/03-probes-and-failure.md) does exactly that and measures it.

**`maxUnavailable: 0`, not 1.** With `maxUnavailable: 1` a rollout runs at
reduced capacity, which is how deploying during a traffic peak becomes an
incident. The cost is headroom for one extra pod.

**A `preStop` sleep, because endpoint removal is not ordered.** When a pod is
deleted, SIGTERM and endpoint removal happen *concurrently*. kube-proxy and the
ingress controller need a moment to stop routing. Without the sleep, requests
arrive at a process already shutting down and clients see resets mid-rollout.
Nothing in Kubernetes serialises this for you. [Lab 02](labs/02-rolling-update.md)
counts the dropped requests.

**Limit memory. Do not limit CPU.** A CPU limit throttles via CFS quota even
when the node is idle, which surfaces as unexplained p99 latency; the CPU
*request* already guarantees a share under contention. Memory is
incompressible, so a memory limit is essential — without one, a single leak
takes the whole node. [Lab 04](labs/04-resources-and-oom.md) shows the
throttling counters and exit code 137.

**`startupProbe` is what lets liveness be aggressive.** Without one you must
choose between an app that is killed before it finishes booting and a liveness
probe too slack to notice a wedged process.

**The ConfigMap is generated, not committed.** `configMapGenerator` appends a
content hash to the name, so changing a value rolls the Deployment. A plain
ConfigMap resource is updated in place and the running pods keep their old
values until something unrelated restarts them. The Helm chart achieves the
same thing with a `checksum/config` pod annotation.

**Let kustomize own the namespace.** Hardcoding `namespace:` in each resource
while the generator emits one without a namespace gives them different
resource IDs — and kustomize then *silently* fails to rewrite the hashed
ConfigMap name into the Deployment. The pods fail at runtime with
`CreateContainerConfigError`, long after apply succeeded. CI asserts the
rewrite happened.

**The HPA owns `replicas`, so the chart must not set it.** If both do, every
`helm upgrade` resets the count and the HPA scales back up moments later — a
visible traffic wobble on every deploy.

**`minAvailable` as a percentage, never equal to `replicas`.** A budget equal
to the replica count permits zero disruption, and `kubectl drain` then blocks
forever during a cluster upgrade.

**NetworkPolicy needs a CNI that enforces it.** kindnet and flannel accept the
objects and enforce nothing. Your policies appear in `kubectl get netpol` and
the workload is wide open — the worst failure mode in Kubernetes networking.
[Lab 05](labs/05-network-policy.md) covers detecting this and installing Calico.

**Deny-all breaks DNS first.** `policyTypes: [Egress]` with `podSelector: {}`
blocks UDP/53 to CoreDNS, and every symptom then looks like a broken
dependency rather than a rule you wrote. Allow both UDP *and* TCP on 53:
resolvers fall back to TCP for large answers, so a UDP-only rule fails
intermittently, which is much harder to diagnose.

**Pod Security Admission is namespace *labels*.** Not a resource — which is why
it is so easy to forget, and a namespace without those labels runs
`privileged` with no restrictions at all. Pin the version so a future
Kubernetes release cannot tighten the profile under a running workload.

**`automountServiceAccountToken: false`.** The default puts a Kubernetes API
credential inside every container, turning a compromised container into a
foothold against the cluster rather than just against the app.

**Pin production by digest, not by tag.** A tag is a mutable pointer: two pods
of one Deployment can run different code, and a rollback does not roll back.

**`targetPort` by name.** The Deployment can then move its container port
without the Service silently pointing at nothing.

**Probes must point at something that exists.** CI caught this one: the probes
asked for `/healthz` and the stock nginx image answers 404 there, so the pod
never became Ready and the rollout timed out. The server block that serves it
now ships in `manifests/base/nginx/default.conf` and in the chart's
`serverConfig` value, and CI asserts offline that the probe path and the served
paths agree. Schema validation cannot catch this class of bug — only actually
running it can.

**Argo CD: `prune` and `selfHeal` are off by default.** Without `prune`, a
deleted manifest keeps running and the repository stops being the source of
truth. Without `selfHeal`, manual `kubectl edit` drift persists. Production
here deliberately has *no* automated sync — so a human still decides, and the
controller does not fight an emergency change mid-incident.

## Validation

```bash
make validate      # everything below, no cluster required
```

| Layer | How it is checked |
|---|---|
| Kustomize | every overlay builds; all 52 resources validated against the Kubernetes 1.31 JSON schemas with `kubeconform -strict` |
| Helm | `helm lint` with each values file; rendered output schema-validated |
| Contract | CI asserts digest pinning, no `replicas` under an HPA, the config checksum, and the ConfigMap name rewrite |
| Real cluster | CI creates a kind cluster, applies with `--dry-run=server`, deploys for real, curls the Service, and verifies the container runs as uid 10001 with a read-only root filesystem |

That last row is the one that matters. A manifest can be schema-perfect and
still not work.

## Requirements

- `kubectl` 1.29+ (kustomize is built in — no separate binary needed)
- `helm` 3.x
- `kind` and Docker, for the local cluster
- `kubeconform`, for offline schema validation (`brew install kubeconform`)

## Related

- 📘 [Kubernetes track](https://computecentral.in/kubernetes/) — the course this implements
- 🔧 [compute-central/ansible-automation](https://github.com/compute-central/ansible-automation) — production Ansible patterns
- 🐍 [compute-central/python-automation](https://github.com/compute-central/python-automation) — `opsctl`, a typed and tested ops CLI

## License

MIT — see [LICENSE](LICENSE). Fork it, change it, use it at work. Contributions
are not accepted; see [CONTRIBUTING.md](CONTRIBUTING.md).
