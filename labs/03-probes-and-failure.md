# Lab 03 — How a Liveness Probe Causes an Outage

**Time:** 20 minutes · **Prerequisites:** Lab 01

## The point

The three probes answer three different questions. Conflating them is the most
common way an operator turns a minor degradation into a total outage, and it
happens because the mistake looks like diligence.

| Probe | Question | On failure |
|---|---|---|
| `startupProbe` | Has it finished booting? | keep waiting; liveness stays suspended |
| `livenessProbe` | Is it wedged? | **restart the container** |
| `readinessProbe` | Should it get traffic now? | remove from Service endpoints |

## 1. Break it: a liveness probe that checks a dependency

This is the trap. It feels thorough: "the pod isn't really healthy if it can't
reach the database." Simulate it with a probe pointed at a dependency that
does not exist:

```bash
kubectl scale deployment/dev-checkout -n checkout-dev --replicas=4
kubectl rollout status deployment/dev-checkout -n checkout-dev

kubectl patch deployment/dev-checkout -n checkout-dev --type=merge -p '
spec:
  template:
    spec:
      containers:
        - name: app
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
              httpHeaders:
                - name: Host
                  value: database-that-does-not-exist
            periodSeconds: 5
            failureThreshold: 2'
```

Watch:

```bash
kubectl get pods -n checkout-dev -w
```

Within a minute, **every replica** enters `CrashLoopBackOff`. Not one. All of
them, simultaneously.

```bash
kubectl get pods -n checkout-dev
kubectl describe pod -n checkout-dev -l app.kubernetes.io/name=checkout | grep -A3 'Liveness probe failed'
```

### Why this is the worst possible outcome

A shared dependency fails. Every pod's liveness probe fails at once. Every pod
restarts at once. Now:

- You have **zero** capacity instead of degraded capacity.
- The restarts hammer the struggling dependency with reconnection storms.
- `CrashLoopBackOff` backoff grows exponentially, so recovery is slow *after*
  the dependency comes back.
- Your logs are gone with the restarted containers, right when you need them.

Had that same check been on the **readiness** probe, the pods would have been
removed from the Service and left running: no restarts, no reconnection storm,
logs intact, and instant recovery when the dependency returned.

> **The rule:** a liveness probe may only check whether *this process* is
> wedged. It must never touch the network, a database, or another service.

## 2. Fix it

```bash
kubectl apply -k manifests/overlays/dev
kubectl rollout status deployment/dev-checkout -n checkout-dev
```

## 3. Break it the other way: no startupProbe on a slow starter

```bash
kubectl patch deployment/dev-checkout -n checkout-dev --type=merge -p '
spec:
  template:
    spec:
      containers:
        - name: app
          command: ["/bin/sh", "-c", "sleep 60 && nginx -g \"daemon off;\""]
          startupProbe: null
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 3'
```

```bash
kubectl get pods -n checkout-dev -w
```

The pod never starts. It is killed at ~15s (3 failures × 5s), restarted, killed
again, forever — an app that needs 60 seconds to boot can never boot.

The fix is not a longer `failureThreshold` on liveness, which would also delay
detection of a genuinely wedged process forever. It is a `startupProbe`: while
one is running, the liveness probe is **suspended entirely**. You get a
generous boot budget *and* tight liveness checking afterwards.

```bash
kubectl apply -k manifests/overlays/dev
kubectl rollout status deployment/dev-checkout -n checkout-dev
```

## 4. Watch readiness do its job

Readiness removes a pod from the Service without restarting it:

```bash
POD=$(kubectl get pod -n checkout-dev -l app.kubernetes.io/name=checkout -o name | head -1)

kubectl get endpointslices -n checkout-dev -o jsonpath='{.items[0].endpoints[*].conditions.ready}{"\n"}'

# Break readiness only, from inside the container
kubectl exec -n checkout-dev "$POD" -- sh -c 'rm -f /tmp/ready' 2>/dev/null || true

kubectl get pod -n checkout-dev "$(basename "$POD")" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
# still 0 -- readiness never restarts anything
```

## What to take away

- **Liveness = in-process only.** Never a dependency. A shared failure plus a
  dependency-checking liveness probe equals a fleet-wide restart.
- **Readiness may check dependencies.** That is the correct place for it:
  traffic stops, the process survives, recovery is immediate.
- **startupProbe exists so liveness can be aggressive.** Without it you must
  choose between slow boots and slow failure detection.

## Cleanup

```bash
kubectl apply -k manifests/overlays/dev
kubectl scale deployment/dev-checkout -n checkout-dev --replicas=1
```
