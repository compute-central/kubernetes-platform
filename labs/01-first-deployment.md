# Lab 01 — What a Deployment Actually Does

**Time:** 15 minutes · **Prerequisites:** `./scripts/bootstrap-kind.sh`

## The point

Almost everyone learns `kubectl apply -f deployment.yaml` before they learn
what is on the other side of it. This lab makes the three-object chain visible,
and then makes the controller visibly fight you.

## 1. Deploy, and look at what was created

```bash
kubectl apply -k manifests/overlays/dev
kubectl get all -n checkout-dev
```

You asked for one object and got three kinds. The chain is:

```
Deployment            you declare intent here: "1 replica of this template"
  └── ReplicaSet      owns a *specific* pod template; a new one per rollout
        └── Pod       the thing that actually runs
```

Confirm the ownership rather than taking it on faith:

```bash
kubectl get rs -n checkout-dev -o jsonpath='{.items[0].metadata.ownerReferences}' | jq
kubectl get pod -n checkout-dev -o jsonpath='{.items[0].metadata.ownerReferences}' | jq
```

Each object names its owner. That chain is what makes cascading deletion work:
delete the Deployment and garbage collection removes everything below it.

## 2. Break it: delete the pod

```bash
kubectl get pods -n checkout-dev -w &
kubectl delete pod -n checkout-dev -l app.kubernetes.io/name=checkout
# a new pod appears within a second or two
kill %1
```

Nothing recreated that pod because you asked it to. The ReplicaSet controller
runs a loop: *observe actual state, compare to desired state, act on the
difference.* You changed actual state; it acted. This reconciliation loop is
the whole of Kubernetes, repeated for every controller.

Try to win:

```bash
for i in 1 2 3; do
  kubectl delete pod -n checkout-dev -l app.kubernetes.io/name=checkout --wait=false
done
kubectl get pods -n checkout-dev
```

You cannot. To actually stop it you have to change *desired* state:

```bash
kubectl scale deployment/dev-checkout -n checkout-dev --replicas=0
kubectl get pods -n checkout-dev
kubectl scale deployment/dev-checkout -n checkout-dev --replicas=1
```

## 3. Why `kubectl run` is not deployment

```bash
kubectl run throwaway --image=nginx -n checkout-dev
kubectl get pod throwaway -n checkout-dev -o jsonpath='{.metadata.ownerReferences}'
# empty -- nothing owns it
kubectl delete pod throwaway -n checkout-dev
# and it is gone for good
```

A bare pod has no controller, so it is never rescheduled, never rolled, and
disappears permanently when its node dies. It is a debugging tool.

## 4. See the reconciliation loop in the event stream

```bash
kubectl get events -n checkout-dev --sort-by=.lastTimestamp | tail -20
```

Read it bottom-up: `ScalingReplicaSet` → `SuccessfulCreate` → `Scheduled` →
`Pulled` → `Created` → `Started`. Each line is a different controller doing one
small job. This event stream is the first place to look when a pod is stuck.

## What to take away

- You never manage pods. You declare desired state; controllers converge on it.
- The ReplicaSet exists so a rollout can hold two pod templates at once, which
  is what Lab 02 is about.
- `ownerReferences` is how deletion cascades, and how `kubectl tree` and the
  dashboard build their views.

## Cleanup

Nothing to do — the next lab uses this deployment.
