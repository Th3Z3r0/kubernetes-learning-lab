# Prerequisites

## Objective

Prepare the Kubernetes lab environment before starting Lesson 01.

## Requirements

- A working Kubernetes cluster
- `kubectl` configured to access the cluster
- The lab namespace `myk8s`

This repository currently uses a local `kind` cluster with one control-plane node and two worker nodes.

## Verify the Cluster

```bash
kubectl get nodes -o wide
```

## Create the Lab Namespace

Apply the namespace manifest:

```bash
kubectl apply -f 00-prerequisites/manifests/namespace-myk8s.yaml
```

Verify it:

```bash
kubectl get namespace myk8s
```

Expected result:

```text
NAME    STATUS   AGE
myk8s   Active   ...
```

## Why Use a Separate Namespace?

The lessons use `myk8s` so lab resources are grouped together and kept separate from Kubernetes system resources.

```text
Kubernetes Cluster
├── kube-system
└── myk8s
    └── Learning lab resources
```

After the namespace is ready, continue with [Lesson 01 — Pod Fundamentals](../01-pod-fundamentals/README.md).
