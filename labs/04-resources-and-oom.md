# Lab 04 — Requests, Limits, QoS, and Getting Killed

**Time:** 25 minutes · **Prerequisites:** Lab 01

## The point

`requests` and `limits` look like a pair of similar knobs. They are completely
different mechanisms: one talks to the scheduler, the other to the kernel. And
CPU and memory behave differently enough that the right answer is usually
"limit memory, do not limit CPU."

| | `requests` | `limits` |
|---|---|---|
| Used by | the scheduler, to place the pod | the kernel, at runtime |
| CPU | guaranteed share under contention | **throttling via CFS quota, even on an idle node** |
| Memory | reserved for placement | **OOMKill when exceeded** |

## 1. QoS class is derived, not declared

```bash
kubectl get pod -n checkout-dev -l app.kubernetes.io/name=checkout \
  -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
```

You never set `qosClass`. Kubernetes computes it:

| Class | Condition | Evicted under node pressure |
|---|---|---|
| `Guaranteed` | requests == limits, for every resource and container | last |
| `Burstable` | requests set, but not equal to limits | second |
| `BestEffort` | nothing set | **first** |

Our dev pod is `Burstable`: it sets a memory limit above its request, and no
CPU limit at all. That is deliberate — see step 4.

Make a `BestEffort` pod and see where it sits:

```bash
kubectl run besteffort --image=nginx -n checkout-dev --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"besteffort","image":"nginx","resources":{}}]}}'
kubectl get pod besteffort -n checkout-dev -o jsonpath='{.status.qosClass}{"\n"}'
kubectl delete pod besteffort -n checkout-dev
```

## 2. Break it: exceed a memory limit

```bash
kubectl apply -n checkout-dev -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: memory-hog
spec:
  restartPolicy: Never
  containers:
    - name: hog
      image: polinux/stress
      resources:
        requests:
          memory: 32Mi
        limits:
          memory: 64Mi
      command: ["stress"]
      # Ask for 150Mi against a 64Mi limit.
      args: ["--vm", "1", "--vm-bytes", "150M", "--vm-hang", "0"]
YAML

kubectl get pod memory-hog -n checkout-dev -w
```

It is killed almost immediately:

```bash
kubectl get pod memory-hog -n checkout-dev \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# OOMKilled

kubectl get pod memory-hog -n checkout-dev \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
# 137  == 128 + 9 (SIGKILL)
```

**Exit code 137 is worth memorising.** It is how OOMKill presents itself, and
it is frequently misread as an application bug.

Note what *did not* happen: the node was fine. There was plenty of free memory.
The container was killed because it crossed **its own** limit — a cgroup limit
enforced by the kernel, not a scheduling decision.

```bash
kubectl delete pod memory-hog -n checkout-dev
```

## 3. Break it differently: unschedulable because of requests

```bash
kubectl apply -n checkout-dev -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: too-big
spec:
  containers:
    - name: app
      image: nginx
      resources:
        requests:
          # More than any kind node has
          memory: 500Gi
          cpu: "200"
YAML

kubectl get pod too-big -n checkout-dev
# Pending

kubectl describe pod too-big -n checkout-dev | grep -A5 Events
# 0/3 nodes are available: Insufficient cpu, Insufficient memory
```

This is `requests` talking to the **scheduler**. Note the pod is Pending
forever, not killed — and that the comparison is against the nodes' allocatable
capacity, not their *current usage*. A node with 8 GiB free can still refuse a
pod requesting 4 GiB if existing pods have already *requested* 6 GiB, even if
they are using almost nothing.

```bash
kubectl delete pod too-big -n checkout-dev
kubectl describe node platform-lab-worker | grep -A8 'Allocated resources'
```

## 4. Why there is no CPU limit in this repository

CPU is **compressible**: a container that wants more just waits. Memory is
**incompressible**: a container that wants more and cannot have it must die.
That asymmetry drives the whole policy.

A CPU limit is enforced by CFS quota: the container gets N microseconds of CPU
per 100ms period, and when it exhausts them it is **throttled until the next
period** — even if every core on the node is idle. For a latency-sensitive
service this shows up as unexplained p99 spikes.

See throttling directly:

```bash
kubectl apply -n checkout-dev -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: throttled
spec:
  restartPolicy: Never
  containers:
    - name: burn
      image: polinux/stress
      resources:
        requests:
          cpu: 100m
        limits:
          cpu: 100m        # 10% of one core
      command: ["stress"]
      args: ["--cpu", "2", "--timeout", "60s"]
YAML

sleep 20
kubectl exec -n checkout-dev throttled -- \
  cat /sys/fs/cgroup/cpu.stat 2>/dev/null | grep -E 'nr_throttled|throttled_usec'
```

`nr_throttled` climbing is the smoking gun. The CPU *request* already
guarantees a proportional share under contention, so the limit buys you
throttling and nothing else.

```bash
kubectl delete pod throttled -n checkout-dev --force --grace-period=0
```

> **The policy this repository follows:** always set both CPU and memory
> *requests* (the scheduler needs them, and the HPA cannot work without a CPU
> request). Always set a memory *limit* (so one leak cannot take the node).
> Leave the CPU limit off unless you specifically need to cap a noisy batch job.

## 5. Eviction: the node runs out, not the container

When a *node* is under memory pressure, the kubelet evicts pods — worst QoS
first, and within a class, whoever most exceeds their request. That is a
different mechanism from OOMKill, and it is why `BestEffort` is a bad idea for
anything you care about.

```bash
kubectl describe node platform-lab-worker | grep -E 'MemoryPressure|DiskPressure'
```

## What to take away

- Exit code **137** = OOMKilled = crossed its own memory limit.
- `Pending` with "Insufficient memory" = `requests` vs node allocatable, which
  counts *requests*, not actual usage.
- QoS class is **derived** from requests and limits, and decides eviction order.
- Limit memory. Do not limit CPU. Always set requests for both.

## Cleanup

```bash
kubectl delete pod memory-hog too-big throttled besteffort -n checkout-dev \
  --ignore-not-found --force --grace-period=0
```
