# Prerequisites

## Objective

Prepare a reproducible Kubernetes lab environment before starting Lesson 01, including the required tooling on a fresh Ubuntu host.

The reference environment is intentionally built so networking, Service dataplane, Ingress, and storage behavior are explicit and testable.

## Minimum System Requirements

This is a **three-node kind lab running Docker, Kubernetes, Cilium, Envoy, Ingress, and dynamic local storage on one Ubuntu host**. The values below are therefore lab sizing guidance, not generic production Kubernetes sizing.

| Resource | Minimum for this lab | Recommended | Notes |
|---|---:|---:|---|
| CPU | **4 vCPU** | **6-8 vCPU** | Kubernetes documents at least 2 CPUs for a control-plane machine, but this lab runs 1 control-plane + 2 workers + Cilium/Envoy on one host. |
| Memory | **8 GiB RAM** | **12-16 GiB RAM** | kind notes that basic clusters need significant Docker memory and that multi-node clusters/additional components require more. |
| Root disk free space | **20 GiB free** | **30+ GiB free** | The bootstrap fails below 20 GiB free and warns below 30 GiB. A 40-50 GiB root disk is a comfortable starting size for a fresh host. |
| Free inodes | **100,000** | **500,000+** | Image extraction and container layers consume many filesystem entries. The bootstrap fails below 100,000 free inodes. |
| Linux kernel | **5.10+** | Current Ubuntu LTS kernel | Cilium 1.20 requires Linux kernel 5.10 or newer (or a documented equivalent). |
| CPU architecture | **amd64 or arm64** | amd64 | The bootstrap and Cilium support both AMD64 and AArch64/ARM64. |
| Operating system | **Ubuntu** | Current Ubuntu LTS | The bootstrap currently supports Ubuntu only. Cilium supports Ubuntu 20.04 and newer. |
| Network | Outbound DNS + HTTPS | Unrestricted outbound Internet access | Required for Ubuntu APT, GitHub, Kubernetes downloads, Docker registries, Quay, and GHCR. |
| Privileges | Normal user with `sudo` | Same | Do not run the bootstrap as root. The script configures Docker access for the normal user. |

The resource values above intentionally include headroom for active smoke tests and later lessons. If CPU or RAM is too small, the cluster may technically start but Pods can become slow, unstable, or fail to schedule during image pulls and concurrent validation.

Useful pre-check commands on a fresh host:

```bash
# CPU
nproc

# Memory
free -h

# Root filesystem capacity and free space
df -h /

# Free inodes
df -i /

# Kernel
uname -r

# Architecture
dpkg --print-architecture

# Ubuntu release
cat /etc/os-release
```

A practical minimum target should look roughly like:

```text
CPU:              4 or more
RAM:              8 GiB or more
Free root disk:   20 GiB or more
Free inodes:      100000 or more
Kernel:           5.10 or newer
Architecture:     amd64 or arm64
OS:               Ubuntu
```

Official background references:

- [Cilium System Requirements](https://docs.cilium.io/en/stable/operations/system_requirements/)
- [kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [Kubernetes kubeadm cluster requirements](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)

## Fresh Ubuntu: First Manual Step

A completely fresh Ubuntu host does not yet have this repository, so the only manual preparation required before using the automation is to install Git and clone the repository.

```bash
sudo apt-get update
sudo apt-get install -y git curl

cd ~
git clone https://github.com/Th3Z3r0/kubernetes-learning-lab.git
cd ~/kubernetes-learning-lab
```

Do not change the executable bit on the tracked repository scripts. Invoke them explicitly with `bash` so their Git file mode remains unchanged.

Verify the clone before continuing:

```bash
git status
ls 00-prerequisites/scripts/
```

Expected scripts:

```text
bootstrap-lab.sh
validate-lab.sh
```

After that, the bootstrap handles the remaining host and cluster preparation:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh
```

Mental model:

```text
Fresh Ubuntu
    ↓
install Git + curl
    ↓
git clone repository
    ↓
bash bootstrap-lab.sh
    ↓
all remaining preparation + validation
```

## Recommended Setup Method

For a fresh Ubuntu host, use the automated bootstrap after cloning the repository:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh
```

The manual commands in [LAB.md](LAB.md) remain useful for learning each installation step and troubleshooting.

Automation behavior and validation stages are documented in [AUTOMATION.md](AUTOMATION.md).

A standalone validator is also available:

```bash
bash 00-prerequisites/scripts/validate-lab.sh --stage all --smoke
```

### Optional live monitoring during Step 7

When the main bootstrap terminal reaches:

```text
[BOOTSTRAP] Step 7 - Install/validate Cilium
```

keep the bootstrap running in that terminal and open one or two additional terminals to observe the cluster converging in real time.

In a second terminal, watch the `kube-system` Pods:

```bash
cd ~/kubernetes-learning-lab
kubectl get pods -n kube-system -o wide -w
```

You should see Cilium/Cilium Envoy Pods start and eventually become `Running` and Ready. CoreDNS may remain `Pending` until Cilium has initialized Pod networking.

In a third terminal, watch Node readiness:

```bash
kubectl get nodes -w
```

The expected transition is:

```text
NotReady
   ↓
Cilium initializes the CNI
   ↓
Ready
```

Both commands use `-w` (`--watch`) and continue streaming changes until you stop them with `Ctrl+C`. They are monitoring-only commands and do not modify the cluster.

If Step 7 appears stuck or fails, stop the watch with `Ctrl+C` and inspect recent events in another terminal:

```bash
kubectl get events -n kube-system \
  --sort-by=.lastTimestamp | tail -n 40
```

For deeper Cilium status after the Cilium agent is running:

```bash
kubectl exec -n kube-system ds/cilium \
  -c cilium-agent -- cilium-dbg status
```

Useful states to look for are:

```text
KubeProxyReplacement: True
Proxy Status:          OK
Cluster health:        3/3 reachable
```

These extra terminals are optional; the bootstrap itself already waits, retries convergence checks, and reports failures. The live views are primarily for learning and troubleshooting.

## Fresh Ubuntu Starting Point

```text
Fresh Ubuntu
    ↓
Git clone
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

The bootstrap also reads the selected Cilium release's official Kubernetes compatibility matrix and chooses the highest digest-pinned Kubernetes node image published by the selected kind release that falls within Cilium's e2e-tested minor versions.

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

By default, the automation uses the current stable tagged kind release and selects a compatible digest-pinned node image. A specific version/image can be supplied for exact reproduction.

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

Long-running waits show visible `[WAIT]` progress so the bootstrap/validator does not appear frozen while Kubernetes/Cilium converges.

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
→ install Git + curl
→ clone repository
→ AUTOMATION.md
→ bash bootstrap-lab.sh

Manual learning/troubleshooting setup
→ LAB.md
```

After the prerequisite environment is complete, continue with [Lesson 01 — Pod Fundamentals](../01-pod-fundamentals/README.md).
