# Prerequisites

## Objective

Prepare a reproducible Kubernetes lab environment before starting Lesson 01, including the required tooling on a fresh Ubuntu host.

The reference environment is intentionally built so the networking and storage behavior used in later lessons is explicit and repeatable.

## Recommended Setup Method

For a fresh Ubuntu host, use the automated bootstrap:

```bash
./00-prerequisites/scripts/bootstrap-lab.sh
```

The manual commands in [LAB.md](LAB.md) remain useful for learning each installation step and for troubleshooting.

The automation design and all validation stages are documented in [AUTOMATION.md](AUTOMATION.md).

A standalone validator is also available:

```bash
./00-prerequisites/scripts/validate-lab.sh --stage all --smoke
```

## Fresh Ubuntu Starting Point

Lesson 00 can start from a newly installed Ubuntu system.

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

## Required Tools

The lab uses:

```text
Git
Docker Engine
kubectl
kind
Helm
```

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

The automation supports the common `amd64` and `arm64` Linux architectures.

The Cilium CLI is not required for this learning path. Cilium troubleshooting uses `cilium-dbg` inside the Cilium agent Pods.

## Version Strategy

There are two complementary goals:

```text
Manual learning path
→ document known/tested versions and exact commands

Automated new-host preparation
→ discover current stable upstream versions
→ validate compatibility before installation
→ record the versions actually used
```

The automated bootstrap resolves stable releases from official upstream sources for:

```text
kubectl
kind
Helm
Cilium
Rancher Local Path Provisioner
```

Docker Engine is installed from Docker's official Ubuntu `stable` APT repository.

Downloaded command-line binaries are SHA-256 validated. After kind creates the cluster, kubectl client/server version skew is checked and corrected if necessary.

Cilium and storage charts are preflight-rendered against the Kubernetes server version before installation. If a future chart changes the values expected by this lab, the script stops instead of silently creating a different architecture.

For exact reproduction or troubleshooting, versions can still be overridden explicitly. See [AUTOMATION.md](AUTOMATION.md).

## Reference Architecture

```text
kind cluster
├── 1 control-plane
├── 2 workers
├── default kind CNI disabled
├── kube-proxy disabled
│
├── Cilium
│   ├── CNI
│   ├── kube-proxy replacement
│   ├── eBPF Service / NodePort dataplane
│   ├── Envoy
│   └── Ingress controller
│
└── Rancher Local Path Provisioner
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

The bootstrap configures the normal Linux user for Docker access instead of running the lab as root.

## Why kubectl?

`kubectl` is the command-line client used to interact with the Kubernetes API:

```text
kubectl
   ↓
Kubernetes API Server
   ↓
Kubernetes objects
```

The automated bootstrap keeps the kubectl client within Kubernetes-supported minor-version skew of the kind cluster API server.

## Why kind?

kind creates the local multi-node Kubernetes environment used throughout the lessons:

```text
kind
├── kind-control-plane
├── kind-worker
└── kind-worker2
```

By default, the automated bootstrap uses the current stable tagged kind release. A specific version can be provided when exact reproduction is required.

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

The Kubernetes API server address is not stored in that file because the kind control-plane container IP can change between cluster recreations. The bootstrap discovers it dynamically and passes it to Helm as `k8sServiceHost` and `k8sServicePort`.

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

## Validation Model

The automated setup does not treat a successful installer exit code as enough proof.

Each major stage is followed by validation:

```text
Host tools
→ binaries + Docker daemon + hello-world

kind
→ 3 nodes + API reachable + kube-proxy absent

Cilium
→ Nodes Ready + DaemonSets Ready + KPR=True
→ Service/DNS smoke test
→ Ingress/NodePort smoke test

Storage
→ StorageClass properties
→ real PVC/PV provisioning
→ write/read test
→ Delete reclaim test

Namespace
→ myk8s Active + authorization check
```

See [AUTOMATION.md](AUTOMATION.md) for all validator commands.

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

## Prerequisite Files

```text
00-prerequisites/
├── README.md
├── LAB.md
├── AUTOMATION.md
├── kind-config.yaml
├── cilium-values.yaml
├── local-path-values.yaml
├── manifests/
│   └── namespace-myk8s.yaml
└── scripts/
    ├── bootstrap-lab.sh
    └── validate-lab.sh
```

## Hands-on Setup

Choose either path:

```text
Automated fresh-host setup
→ AUTOMATION.md
→ bootstrap-lab.sh

Manual learning/troubleshooting setup
→ LAB.md
```

After the prerequisite environment is complete, continue with [Lesson 01 — Pod Fundamentals](../01-pod-fundamentals/README.md).
