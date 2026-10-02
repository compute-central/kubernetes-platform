# Labs

Five labs, each one built around a failure you will eventually cause in
production. Every lab runs on the local kind cluster and each one ends by
breaking something on purpose, because a concept you have only seen working is
a concept you do not yet understand.

```bash
./scripts/bootstrap-kind.sh
```

| Lab | What you break, and what you learn |
|---|---|
| [01 — First Deployment](01-first-deployment.md) | Delete a pod and watch the controller fight you. Deployment → ReplicaSet → Pod, and why `kubectl run` is not how anything real is deployed. |
| [02 — Rolling Update](02-rolling-update.md) | Roll out with `maxUnavailable: 1` under load and count the dropped requests. Then fix it. |
| [03 — Probes and Failure](03-probes-and-failure.md) | Point a liveness probe at a dependency and take down every replica at once. The single most common self-inflicted Kubernetes outage. |
| [04 — Resources and OOM](04-resources-and-oom.md) | Get a pod OOMKilled, then evicted. QoS classes, and why a CPU limit hurts while a memory limit helps. |
| [05 — Network Policy](05-network-policy.md) | Apply deny-all and watch DNS break first. Why kindnet silently ignores your policies. |

Each lab is self-contained and cleans up after itself.
