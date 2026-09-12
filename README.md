# Kubernetes Learning Lab

This repository is a hands-on Kubernetes learning path built around real experiments, expected results, intentional failures, and troubleshooting.

The goal is not to memorize YAML. The goal is to understand:

```text
What is the object?
Why does it exist?
How does it relate to other objects?
Which component manages it?
How do I test it?
What should I expect to see?
How do I troubleshoot it when it fails?
```

## Lab Host Requirements

This lab runs **three kind Kubernetes nodes plus Cilium, Envoy, Ingress, and local storage on one Ubuntu host**.

| Resource | Minimum | Recommended |
|---|---:|---:|
| CPU | 4 vCPU | 6-8 vCPU |
| Memory | 8 GiB | 12-16 GiB |
| Root disk free space | 20 GiB free | 30+ GiB free |
| Free inodes | 100,000 | 500,000+ |
| Linux kernel | 5.10+ | Current Ubuntu LTS kernel |
| Architecture | amd64 or arm64 | amd64 |
| OS | Ubuntu | Current Ubuntu LTS |

The bootstrap currently **enforces disk and inode capacity** before building the cluster. CPU/RAM values are lab sizing guidance with headroom for the three-node cluster, Cilium/Envoy, active smoke tests, and later lessons.

See [Lesson 00 Prerequisites](00-prerequisites/README.md#minimum-system-requirements) for the detailed requirements, pre-check commands, network/privilege requirements, and upstream references.

## Fresh Ubuntu Quick Start

For a completely fresh Ubuntu host, the only manual preparation required before using the repository automation is to install Git and clone this repository:

```bash
sudo apt-get update
sudo apt-get install -y git curl

cd ~
git clone https://github.com/Th3Z3r0/kubernetes-learning-lab.git
cd ~/kubernetes-learning-lab

bash 00-prerequisites/scripts/bootstrap-lab.sh
```

Run the repository scripts explicitly with `bash`. Do not change the executable bit on the tracked scripts; file-mode changes can make the Git working tree appear modified and block commands such as `git pull --rebase`.

The bootstrap then installs/configures the remaining host tools and lab infrastructure and validates every major stage.

```text
Fresh Ubuntu
    ↓
Git + curl
    ↓
git clone
    ↓
bash bootstrap-lab.sh
    ↓
Docker + kubectl + kind + Helm
    ↓
kind + Cilium + storage
    ↓
validation / smoke tests
    ↓
Ready for Lesson 01
```

See [Lesson 00 Automation](00-prerequisites/AUTOMATION.md) for version selection, compatibility guards, validation stages, rerun behavior, and troubleshooting.

## How to Use This Repository

Run the lessons in order. Unless a lesson says otherwise, run commands from the repository root:

```bash
cd ~/kubernetes-learning-lab
```

Each lesson has two documents:

- `README.md` — concept notes, explanations, observations, and mental models
- `LAB.md` — reproducible step-by-step lab with commands, testing steps, expected results, troubleshooting, cleanup, and required end state

For someone following the repository from scratch, **use `LAB.md` as the primary runbook** and use `README.md` for deeper explanation.

> Pod names, ReplicaSet hashes, IP addresses, ages, EndpointSlice names, PV names, Node selection, and some timing will differ between clusters. Expected results describe behavior to verify rather than requiring identical dynamic values.

## Learning Path

| Lesson | Topic | Theory Notes | Hands-on Lab | Status |
|---|---|---|---|---|
| 00 | Prerequisites | [README](00-prerequisites/README.md) | [LAB](00-prerequisites/LAB.md) | Completed |
| 01 | Pod Fundamentals | [README](01-pod-fundamentals/README.md) | [LAB](01-pod-fundamentals/LAB.md) | Completed |
| 02 | Deployment and ReplicaSet | [README](02-deployment-replicaset/README.md) | [LAB](02-deployment-replicaset/LAB.md) | Completed |
| 03 | Labels, Selectors, Service, EndpointSlice, and Kubernetes DNS | [README](03-labels-selectors-service/README.md) | [LAB](03-labels-selectors-service/LAB.md) | Completed |
| 04 | ConfigMap and Secret | [README](04-configmap-secret/README.md) | [LAB](04-configmap-secret/LAB.md) | Completed |
| 05 | Storage: Volume, PV, PVC, and StorageClass | [README](05-storage/README.md) | [LAB](05-storage/LAB.md) | Completed |
| 06 | Ingress and External Access | — | — | Next |
| 07 | RBAC and Kubernetes Security | — | — | Planned |
| 08 | NetworkPolicy | — | — | Planned |

## Reference Lab Environment

The reference architecture is:

```text
kind
├── 1 control-plane
├── 2 workers
├── containerd
├── Pod CIDR:     10.10.0.0/16
├── Service CIDR: 10.11.0.0/16
│
├── default kind CNI disabled
├── kube-proxy disabled
│
├── Cilium
│   ├── CNI
│   ├── kube-proxy replacement
│   ├── eBPF Service / NodePort dataplane
│   ├── Envoy
│   └── Cilium Ingress Controller
│
├── dynamic local storage
│   ├── preferred: compatible kind-provided Local Path Provisioner
│   └── fallback: Rancher Local Path Provisioner via Helm
│       └── default StorageClass: standard
│
└── lab namespace: myk8s
```

The automated bootstrap discovers current stable upstream versions and validates compatibility before using them. Exact versions can be overridden when reproducibility requires pinning.

Reference node layout:

```text
kind-control-plane
kind-worker
kind-worker2
```

Lesson 00 contains the complete reproducible setup including:

```text
00-prerequisites/kind-config.yaml
00-prerequisites/cilium-values.yaml
00-prerequisites/local-path-values.yaml
00-prerequisites/scripts/bootstrap-lab.sh
00-prerequisites/scripts/validate-lab.sh
```

The kind configuration deliberately disables the default CNI and kube-proxy. Nodes are expected to be temporarily `NotReady` until Cilium is installed.

Other Kubernetes clusters can also be used, but implementation-specific observations such as Node names, CNI behavior, Service dataplane, networking addresses, storage classes, provisioners, and PV backing types can differ.

## Core Kubernetes Relationships

### Workload hierarchy

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
    ↓
Container
```

### Stable application networking

```text
Service
    ↓
Selector
    ↓
EndpointSlice
    ↓
Pods
```

In the reference lab, Cilium implements the Service dataplane:

```text
Service / EndpointSlice
        ↓
Cilium eBPF service state
        ↓
Backend Pod
```

### Application configuration

```text
ConfigMap / Secret
        ↓
Environment Variable or Volume
        ↓
Pod
```

### Persistent storage

```text
Pod
 ↓
PVC
 ↓
StorageClass / Provisioner
 ↓
PV
 ↓
Storage backend
```

Simple storage memory aid:

```text
PVC          = WHAT storage is requested
StorageClass = HOW dynamic storage is provided
PV           = allocated storage resource
```

## Kubernetes Control Flow

```text
kubectl
   ↓
API Server
   ↓
Scheduler / Controllers
   ↓
Node
   ↓
kubelet
   ↓
Container Runtime
   ↓
Container
```

| Component | Main responsibility |
|---|---|
| `kubectl` | Sends requests to the Kubernetes API |
| API Server | Receives requests and exposes/manages Kubernetes API objects |
| Scheduler | Selects a suitable Node for unscheduled Pods |
| Controllers | Reconcile desired and observed state |
| kubelet | Ensures assigned Pods are running on its Node |
| Container Runtime | Pulls images and manages containers |
| Cilium | Provides the reference lab CNI and Service/NodePort dataplane |
| Envoy | Provides L7 proxying used by the Cilium Ingress dataplane |

## Important Mental Model

```text
metadata = Who am I?
spec     = What do I want?
status   = What is actually happening?
```

Reconciliation:

```text
Desired State
    ↓
   spec
    ↓
Controllers
    ↓
Observed State
    ↓
  status
```

## Repository Structure

```text
kubernetes-learning-lab/
│
├── README.md
│
├── 00-prerequisites/
│   ├── README.md
│   ├── LAB.md
│   ├── AUTOMATION.md
│   ├── kind-config.yaml
│   ├── cilium-values.yaml
│   ├── local-path-values.yaml
│   ├── manifests/
│   │   └── namespace-myk8s.yaml
│   └── scripts/
│       ├── bootstrap-lab.sh
│       └── validate-lab.sh
│
├── 01-pod-fundamentals/
│   ├── README.md
│   ├── LAB.md
│   └── manifests/
│       ├── pod-nginx.yaml
│       └── pod-bad-nginx.yaml
│
├── 02-deployment-replicaset/
│   ├── README.md
│   ├── LAB.md
│   └── manifests/
│       └── deployment-web.yaml
│
├── 03-labels-selectors-service/
│   ├── README.md
│   ├── LAB.md
│   └── manifests/
│       ├── service-web.yaml
│       └── curl-client.yaml
│
├── 04-configmap-secret/
│   ├── README.md
│   ├── LAB.md
│   └── manifests/
│       ├── configmap-web-content.yaml
│       ├── deployment-web-configmap.yaml
│       ├── configmap-app-settings.yaml
│       ├── secret-app-example.yaml
│       ├── secret-reader.yaml
│       ├── broken-config-pod.yaml
│       └── broken-secret-pod.yaml
│
└── 05-storage/
    ├── README.md
    ├── LAB.md
    └── manifests/
        ├── emptydir-pod.yaml
        ├── pvc-demo.yaml
        ├── pvc-pod.yaml
        ├── broken-pvc.yaml
        ├── fixed-pvc.yaml
        ├── broken-storage-pod.yaml
        └── emptydir-restart.yaml
```

Future lesson directories will be added only when their labs begin.

## Lesson Documentation Standard

Every lesson should provide enough information for another learner to reproduce the experiment without relying on chat history.

Each lesson must include:

1. Objective and problem being solved
2. Prerequisite/start-state check
3. Required manifests or resources
4. Exact commands to run
5. Testing/verification step after each major action
6. Expected result or expected failure
7. Explanation of what the result proves
8. Intentional break/failure exercise where useful
9. Troubleshooting commands and interpretation
10. Cleanup instructions
11. Required end state for the next lesson
12. Link to the next lesson

The `README.md` captures theory and learning notes. The `LAB.md` is the reproducible runbook.

## Common Troubleshooting Commands

```bash
kubectl get nodes -o wide
kubectl get pods -n myk8s -o wide
kubectl describe pod <pod-name> -n myk8s
kubectl get <resource> <name> -n myk8s -o yaml
kubectl get events -n myk8s --sort-by=.lastTimestamp
```

For Cilium/networking troubleshooting:

```bash
kubectl get pods -n kube-system -o wide
kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg status
kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg service list
```

For storage troubleshooting:

```bash
kubectl get storageclass
kubectl get pvc -A
kubectl get pv
kubectl describe pvc <pvc-name> -n myk8s
kubectl describe pv <pv-name>
```

A useful troubleshooting sequence is:

```text
What object is failing?
        ↓
What state is it in?
        ↓
kubectl describe
        ↓
Conditions / Events
        ↓
Which lifecycle stage failed?
        ↓
Verify the dependency at that stage
```

## Current Progress

### Lesson 00 — Prerequisites

- Fresh Ubuntu bootstrap entrypoint
- Automated host-tool preparation and validation
- Reproducible three-node kind topology
- Default CNI disabled
- kube-proxy disabled
- Cilium CNI and kube-proxy replacement
- Cilium Envoy and IngressClass
- Compatible dynamic local storage with `standard` default StorageClass
- Active networking and storage smoke tests
- `myk8s` namespace

### Lesson 01 — Pod Fundamentals

- Pod structure and lifecycle
- API Server, Scheduler, kubelet, container runtime
- `spec` vs `status`
- `ErrImagePull` / `ImagePullBackOff`
- Standalone Pod deletion behavior

### Lesson 02 — Deployment and ReplicaSet

- Deployment → ReplicaSet → Pod ownership
- Reconciliation and self-healing
- Scaling
- Labels/selectors and pod-template-hash
- Rolling updates and rollback

### Lesson 03 — Service and Kubernetes DNS

- Labels/selectors
- ClusterIP Service and `port` vs `targetPort`
- EndpointSlice
- Service failure/recovery
- Service dataplane observation
- Backend traffic distribution
- CoreDNS and cross-namespace discovery

### Lesson 04 — ConfigMap and Secret

- Mounted configuration and environment variables
- Update behavior
- Base64 vs encryption
- Secret mounted files
- `CreateContainerConfigError`
- Missing ConfigMap/Secret recovery

### Lesson 05 — Storage

- Container filesystem vs Pod-lifetime `emptyDir`
- Prove `emptyDir` is deleted with the Pod
- Prove `emptyDir` survives a container restart inside the same Pod
- PVC → StorageClass → Provisioner → PV relationship
- Dynamic provisioning with `WaitForFirstConsumer`
- PVC/PV binding and `ReadWriteOnce`
- Persistent data surviving Pod recreation
- PVC deletion with `ReclaimPolicy=Delete`
- Local-path/HostPath behavior in the reference kind lab
- ConfigMap vs persistent application data
- Broken StorageClass troubleshooting
- `Pending` as expected waiting state vs actual provisioning failure

## Next

**Lesson 06 — Ingress and External Access**
