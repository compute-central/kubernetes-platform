# Lab 02 — A Rollout That Drops Requests, and One That Does Not

**Time:** 25 minutes · **Prerequisites:** Lab 01

## The point

"Kubernetes gives you zero-downtime deploys" is only true if you configure
three things correctly. Here you will measure actual dropped requests, then fix
them one cause at a time.

## 1. Scale up and start generating load

```bash
kubectl scale deployment/dev-checkout -n checkout-dev --replicas=4
kubectl rollout status deployment/dev-checkout -n checkout-dev
```

In a second terminal, hammer it through the ingress and count failures:

```bash
while true; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
    -H 'Host: checkout.localtest.me' http://localhost/healthz)
  [ "$code" = "200" ] || echo "$(date +%T) FAILED: $code"
  sleep 0.1
done
```

## 2. Break it: roll out the careless way

```bash
kubectl patch deployment/dev-checkout -n checkout-dev --type=merge -p '
spec:
  strategy:
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
  template:
    spec:
      containers:
        - name: app
          lifecycle: null'
```

Two deliberate mistakes: `maxUnavailable: 1` with `maxSurge: 0` means capacity
*drops* during the rollout, and removing the `preStop` hook means pods stop
accepting connections while traffic is still being routed to them.

Trigger a rollout:

```bash
kubectl set env deployment/dev-checkout -n checkout-dev ROLLOUT=1 -n checkout-dev
kubectl rollout status deployment/dev-checkout -n checkout-dev
```

Watch the load terminal. You will see `FAILED: 502` and `FAILED: 000`.

### Why

Two independent causes, and this is the part worth internalising:

1. **Capacity dipped.** `maxUnavailable: 1, maxSurge: 0` means Kubernetes
   terminates a pod *before* its replacement is ready. Four replicas become
   three while the new one boots.

2. **Endpoint removal and SIGTERM are concurrent, not ordered.** When a pod is
   deleted, the kubelet sends SIGTERM *at the same time* as the endpoint
   controller starts removing it from the Service. kube-proxy and the ingress
   controller take a moment to notice. During that window, traffic arrives at a
   process that is already shutting down.

   Nothing in Kubernetes serialises these. The only fix is to make the pod keep
   serving for a few seconds after SIGTERM — which is exactly what a `preStop`
   sleep does.

## 3. Fix it

```bash
kubectl apply -k manifests/overlays/dev
kubectl rollout status deployment/dev-checkout -n checkout-dev
kubectl scale deployment/dev-checkout -n checkout-dev --replicas=4
```

Check what changed back:

```bash
kubectl get deployment/dev-checkout -n checkout-dev \
  -o jsonpath='{.spec.strategy.rollingUpdate}{"\n"}'
# {"maxSurge":1,"maxUnavailable":0}

kubectl get deployment/dev-checkout -n checkout-dev \
  -o jsonpath='{.spec.template.spec.containers[0].lifecycle}{"\n"}'
```

Roll again with the load test running:

```bash
kubectl set env deployment/dev-checkout -n checkout-dev ROLLOUT=2
kubectl rollout status deployment/dev-checkout -n checkout-dev
```

No failures. `maxUnavailable: 0` keeps capacity at four throughout, and the
`preStop` sleep covers the endpoint-propagation window.

## 4. The third requirement: a readiness probe that tells the truth

`maxUnavailable: 0` only works because readiness is accurate. A pod that
reports Ready before it can serve gets added to the Service and receives
traffic it cannot handle — and the rollout proceeds, believing capacity is
fine.

Prove it by lying about readiness:

```bash
kubectl patch deployment/dev-checkout -n checkout-dev --type=merge -p '
spec:
  template:
    spec:
      containers:
        - name: app
          readinessProbe: null'
kubectl set env deployment/dev-checkout -n checkout-dev ROLLOUT=3
```

With no readiness probe, a pod counts as Ready the moment its container
starts. Failures return.

Restore:

```bash
kubectl apply -k manifests/overlays/dev
```

## 5. Rollback

```bash
kubectl rollout history deployment/dev-checkout -n checkout-dev
kubectl rollout undo deployment/dev-checkout -n checkout-dev
```

Rollback works by scaling the *previous ReplicaSet* back up — which is why
ReplicaSets exist as a separate object, and why `revisionHistoryLimit`
determines how far back you can go.

## What to take away

Zero-downtime rollout needs all three, not any one:

| Setting | Without it |
|---|---|
| `maxUnavailable: 0` | capacity dips mid-rollout |
| `preStop` sleep ≥ endpoint propagation | in-flight requests are reset |
| An honest readiness probe | traffic reaches pods that cannot serve |

## Cleanup

```bash
kubectl scale deployment/dev-checkout -n checkout-dev --replicas=1
```
Stop the load loop with Ctrl-C.
