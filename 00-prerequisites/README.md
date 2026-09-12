# Prerequisites

## Objective

Prepare a reproducible Kubernetes lab environment before starting Lesson 01, including the required tooling on a fresh Ubuntu host.

The reference environment is intentionally built so networking, Service dataplane, Ingress, and storage behavior are explicit and testable.

## Recommended Setup Method

For a fresh Ubuntu host, use the automated bootstrap:

```bash
./00-prerequisites/scripts/bootstrap-lab.sh
```

The manual commands in [LAB.md](LAB.md) remain useful for learning each installation step and troubleshooting.

Automation behavior and validation stages are documented in [AUTOMATION.md](AUTOMATION.md).

A standalone validator is also available:

```bash
./00-prerequisites/scripts/validate-lab.sh --stage all --smoke
```

## Fresh Ubuntu Starting Point

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
compatible dynamic local storage
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

The automation supports common `amd64` and `arm64` Linux architectures.

The Cilium CLI is not required. Cilium troubleshooting uses `cilium-dbg` inside the Cilium agent Pods.

## Version Strategy

There are two complementary goals:

```text
Manual learning path
→ document known/tested commands

Automated new-host preparation
→ discover current stable upstream versions
→ validate compatibility before installation
→ record the versions and implementations actually used
```

The automated bootstrap resolves stable upstream releases for:

```text
kubectl
kind
Helm
Cilium
Rancher Local Path Provisioner fallback
```

Docker Engine comes from Docker's official Ubuntu `stable` APT repository.

Downloaded CLI binaries are SHA-256 validated. After kind creates the cluster, kubectl client/server version skew is checked and corrected when necessary.

Cilium is Helm-preflighted against the Kubernetes server version before installation. The Local Path Helm chart is preflighted only when the cluster does not already provide compatible storage.

Exact versions can still be overridden explicitly for troubleshooting or reproduction. See [AUTOMATION.md](AUTOMATION.md).

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
└── dynamic local storage
    ├── preferred: compatible kind-provided Local Path Provisioner
    └── fallback: Rancher Local Path Provisioner via Helm
         ↓
       default StorageClass: standard
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

Docker must therefore be healthy before kind can create the cluster.

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

The automated bootstrap keeps the kubectl client within the supported minor-version skew of the kind cluster API server.

## Why kind?

kind creates the local multi-node Kubernetes environment used throughout the lessons:

```text
kind
├── kind-control-plane
├── kind-worker
└── kind-worker2
```

By default, the automation uses the current stable tagged kind release. A specific version can be supplied for exact reproduction.

## Why Helm?

Helm is required for Cilium and is also available as the fallback installation method for Local Path Provisioner:

```text
Helm
├── Cilium
└── Local Path Provisioner fallback only
```

Reusable values files are stored in the repository instead of relying on long one-off command lines.

## Why Disable the Default CNI and kube-proxy?

The lab uses Cilium as both the CNI and Kubernetes Service dataplane.

```text
kind default CNI   → disabled
kube-proxy         → disabled
Cilium             → provides Pod networking
Cilium eBPF        → provides Service / NodePort handling
Envoy              → provides L7 / Ingress dataplane
```

This avoids mixing kube-proxy with Cilium kube-proxy replacement and makes later Service and Ingress experiments easier to reason about.

## Expected Bootstrap Behavior

Immediately after kind cluster creation, Nodes are expected to be `NotReady` because no CNI has been installed yet.

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

That temporary `NotReady` state is expected and part of the lab.

## Cilium Configuration

Reusable Cilium settings are stored in:

```text
00-prerequisites/cilium-values.yaml
```

The Kubernetes API server address is not hard-coded because the kind control-plane container IP can change. The bootstrap discovers it dynamically and passes it to Helm as `k8sServiceHost` and `k8sServicePort`.

Key settings:

```text
ipam.mode                  = kubernetes
kubeProxyReplacement       = true
envoy.enabled              = true
ingressController.enabled  = true
Ingress LB mode            = dedicated
```

## Storage Configuration

Lesson 05 expects dynamic local storage with these properties:

```text
Name:               standard
Provisioner:        rancher.io/local-path
Default:            yes
ReclaimPolicy:      Delete
VolumeBindingMode:  WaitForFirstConsumer
Backing type:       local Node storage
```

Modern kind node images can already provide a compatible Local Path Provisioner. The automation therefore checks behavior before installing anything:

```text
compatible standard StorageClass + Ready provisioner?
        |
        +-- yes --> use it
        |
        +-- no  --> install Rancher Local Path via Helm fallback
```

The fallback values remain in:

```text
00-prerequisites/local-path-values.yaml
```

This avoids creating a redundant second `rancher.io/local-path` provisioner.

Local-path storage is intended only for this learning environment. It is local to a kind Node and is not highly available cloud/distributed storage.

## Validation Model

A successful install command is not considered enough proof.

```text
Host tools
→ binaries + Docker daemon + hello-world

kind
→ 3 Nodes + API reachable + kube-proxy absent

Cilium
→ Nodes Ready + DaemonSets Ready + KPR=True
→ Service/DNS smoke test
→ Ingress/NodePort smoke test

Storage
→ required StorageClass behavior
→ Ready local-path provisioner
→ identify source: kind-builtin / Helm / existing non-Helm
→ real PVC/PV provisioning
→ write/read test
→ Delete reclaim test

Namespace
→ myk8s Active + authorization check
```

See [AUTOMATION.md](AUTOMATION.md) for validator commands.

## Lab Namespace

The lessons use `myk8s` so application resources are separate from system components:

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
