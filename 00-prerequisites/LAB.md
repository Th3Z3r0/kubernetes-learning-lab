# Lesson 00 Hands-on Lab — Prerequisites

Run all commands from the repository root unless stated otherwise.

## Goal

Prepare a working Kubernetes lab with one control-plane node, two worker nodes, and the `myk8s` namespace.

## Step 1 — Verify required tools

```bash
kubectl version --client
kind version
```

### Expected result

Both commands should return version information without errors.

If `kind` is not installed but you already have another working Kubernetes cluster, you may continue using that cluster.

---

## Step 2 — Verify cluster access

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

### Expected result

`kubectl cluster-info` should return Kubernetes control-plane information and `kubectl get nodes` should show reachable nodes in `Ready` state.

For the reference kind lab, the expected shape is:

```text
NAME                 STATUS   ROLES
kind-control-plane   Ready    control-plane
kind-worker          Ready    <none>
kind-worker2         Ready    <none>
```

Exact Kubernetes versions, IP addresses, and ages can differ.

---

## Step 3 — Optional: create the reference kind cluster

Skip this step if you already have a working cluster.

Check whether a kind cluster already exists:

```bash
kind get clusters
```

If no cluster named `kind` exists, create it:

```bash
kind create cluster --config 00-prerequisites/kind-config.yaml
```

Verify:

```bash
kubectl get nodes
```

### Expected result

Three nodes should become `Ready`: one control-plane and two workers.

---

## Step 4 — Create the lab namespace

```bash
kubectl apply -f 00-prerequisites/manifests/namespace-myk8s.yaml
```

### Expected result

```text
namespace/myk8s created
```

If it already exists, this is also valid:

```text
namespace/myk8s unchanged
```

Verify:

```bash
kubectl get namespace myk8s
```

### Expected result

```text
NAME    STATUS   AGE
myk8s   Active   ...
```

---

## Step 5 — Final readiness test

```bash
kubectl auth can-i create pods -n myk8s
kubectl get all -n myk8s
```

### Expected result

The first command should normally return:

```text
yes
```

The namespace may contain no application resources yet. That is expected.

## End state

```text
Kubernetes cluster reachable
        +
myk8s namespace Active
        ↓
Ready for Lesson 01
```

Continue with [Lesson 01 Hands-on Lab](../01-pod-fundamentals/LAB.md).
