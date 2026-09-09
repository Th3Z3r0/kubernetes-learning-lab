# Prerequisites

## Objective

Prepare a reproducible Kubernetes lab environment before starting Lesson 01, including the required tooling on a fresh Ubuntu host.

The reference environment is intentionally built so the networking and storage behavior used in later lessons is explicit and repeatable.

## Fresh Ubuntu Starting Point

Lesson 00 can start from a newly installed Ubuntu system.

The setup flow is:

```text
Fresh Ubuntu
    ↓
Base packages
    ↓
Docker Engine
    ↓
kubectl + kind + Helm
    ↓
kind cluster
    ↓
Cilium
    ↓
Local Path Provisioner
    ↓
myk8s namespace
```

The hands-on runbook installs and verifies the required tools before creating Kubernetes.

## Required Tools

The lab uses:

```text
Git
Docker Engine
kubectl
kind
Helm
```

Pinned/tested command-line versions for this reference setup:

```text
kubectl:  1.36.1
kind:     0.33.0
Helm:     4.2.4
```

Docker Engine is installed from Docker's official Ubuntu APT repository rather than pinning a particular package build.

Supporting Ubuntu packages include:

```text
ca-certificates
curl
gnupg
git
jq
openssl
tar
```

The runbook supports the common `amd64` and `arm64` Linux architectures and verifies downloaded `kubectl` and `kind` binaries with SHA-256 checksums.

The Cilium CLI is not required for this learning path. Cilium troubleshooting uses `cilium-dbg` inside the Cilium agent Pods.

## Reference Architecture

```text
kind cluster
├── 1 control-plane
├── 2 workers
├── default kind CNI disabled
├── kube-proxy disabled
│
├── Cilium 1.20.1
│   ├── CNI
│   ├── kube-proxy replacement
│   ├── Envoy
│   └── Ingress controller
│
└── Rancher Local Path Provisioner 0.0.37
    └── default StorageClass: standard
```

Reference network ranges:

```text
Pod CIDR:     10.10.0.0/16
Service CIDR: 10.11.0.0/16
```

The lab namespace is:

```text
myk8s
```

## Why Docker?

kind runs Kubernetes Nodes as Docker containers:

```text
Ubuntu host
   ↓
Docker Engine
   ↓
kind-control-plane
kind-worker
kind-worker2
```

Docker therefore has to be healthy before kind can create the cluster.

The lab configures the current Linux user to access Docker without `sudo`, because kind is intended to be run as the normal lab user.

## Why kubectl?

`kubectl` is the command-line client used to interact with the Kubernetes API:

```text
kubectl
   ↓
Kubernetes API Server
   ↓
Kubernetes objects
```

The reference setup pins `kubectl` to the Kubernetes version used by the tested kind cluster.

## Why kind?

kind creates the local multi-node Kubernetes environment used throughout the lessons:

```text
kind
├── kind-control-plane
├── kind-worker
└── kind-worker2
```

The reference setup pins kind `v0.33.0` so the cluster build is repeatable.

## Why Helm?

Helm is used to install and configure infrastructure components used by the lab:

```text
Helm
├── Cilium
└── Rancher Local Path Provisioner
```

Reusable values files are stored in the repository instead of relying on long one-off command lines.

## Why Disable the Default CNI and kube-proxy?

The lab uses Cilium as both the CNI and the Kubernetes Service dataplane.

```text
kind default CNI   → disabled
kube-proxy         → disabled
Cilium             → provides Pod networking
Cilium eBPF        → provides Service / NodePort handling
Envoy              → provides L7 / Ingress dataplane
```

This avoids running kube-proxy and Cilium kube-proxy replacement at the same time and makes later Service and Ingress experiments easier to reason about.

## Expected Bootstrap Behavior

Immediately after the kind cluster is created, the Nodes are expected to be `NotReady` because no CNI has been installed yet.

```text
kind cluster created
      ↓
CNI intentionally absent
      ↓
Nodes NotReady
CoreDNS Pending
```

After Cilium is installed:

```text
Cilium starts
      ↓
CNI initialized
      ↓
Nodes Ready
CoreDNS Running
```

This temporary `NotReady` state is expected and is part of the lab.

## Cilium Configuration

The reusable Cilium settings are stored in:

```text
00-prerequisites/cilium-values.yaml
```

The Kubernetes API server address is not stored in that file because the kind control-plane container IP can change between cluster recreations. The hands-on lab discovers it dynamically and passes it to Helm as `k8sServiceHost` and `k8sServicePort`.

Key settings:

```text
ipam.mode                  = kubernetes
kubeProxyReplacement       = true
envoy.enabled              = true
ingressController.enabled  = true
Ingress LB mode            = dedicated
```

## Storage Configuration

Lesson 05 requires dynamic persistent-volume provisioning.

The reference lab installs Rancher Local Path Provisioner and creates this StorageClass:

```text
Name:               standard
Provisioner:        rancher.io/local-path
Default:            yes
ReclaimPolicy:      Delete
VolumeBindingMode:  WaitForFirstConsumer
Backing type:       local HostPath-style storage
```

The reusable Helm values are stored in:

```text
00-prerequisites/local-path-values.yaml
```

This storage is intended for learning. It is local to a kind Node and should not be confused with highly available cloud or distributed storage.

## Lab Namespace

The lessons use `myk8s` so application resources are grouped separately from system components:

```text
Kubernetes Cluster
├── kube-system
├── local-path-storage
└── myk8s
    └── learning lab resources
```

The namespace manifest is:

```text
00-prerequisites/manifests/namespace-myk8s.yaml
```

## Hands-on Setup

Use [LAB.md](LAB.md) for the complete fresh-Ubuntu tool installation, cluster creation, Cilium installation, storage provisioning, verification, and namespace setup procedure.

After the prerequisite lab is complete, continue with [Lesson 01 — Pod Fundamentals](../01-pod-fundamentals/README.md).
