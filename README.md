# Kubernetes Learning Lab

This repository contains hands-on Kubernetes learning notes, manifests, experiments, and troubleshooting exercises.

The goal is to understand Kubernetes objects, how they work together, which components manage them, and how to troubleshoot common failures without trying to memorize every YAML parameter.

## Learning Approach

For each topic, this lab focuses on:

* Why the object exists
* What problem it solves
* How it relates to other Kubernetes objects
* Which Kubernetes components are involved
* What is essential to understand
* What can be learned later
* How to create and inspect the object
* How to break the workload intentionally
* How to troubleshoot the resulting failure

Each lesson folder contains a detailed `README.md` with the concept, lab steps, observations, commands, troubleshooting notes, and key takeaways.

## Learning Path

| Lesson | Topic                                             | Status    |
| ------ | ------------------------------------------------- | --------- |
| 01     | [Pod Fundamentals](01-pod-fundamentals/README.md) | Completed |
| 02     | [Deployment and ReplicaSet](02-deployment-replicaset/README.md)                         | Completed |
| 03     | Labels, Selectors, and Service                    | Planned   |
| 04     | ConfigMap and Secret                              | Planned   |
| 05     | Storage: Volume, PV, and PVC                      | Planned   |
| 06     | Ingress and External Access                       | Planned   |
| 07     | RBAC and Kubernetes Security                      | Planned   |
| 08     | NetworkPolicy                                     | Planned   |

## Core Kubernetes Relationships

The main workload and networking relationships explored in this repository are:

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
    ↓
Container
```

A Service provides stable network access to Pods:

```text
Service
    ↓
Label Selector
    ↓
Pods
```

## Kubernetes Control Flow

A simplified Kubernetes control flow looks like this:

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

### Component Responsibilities

| Component         | Responsibility                                    |
| ----------------- | ------------------------------------------------- |
| `kubectl`         | Sends requests to the Kubernetes API              |
| API Server        | Receives requests and manages Kubernetes objects  |
| Scheduler         | Selects a suitable Node for unscheduled Pods      |
| Controllers       | Continuously reconcile desired and observed state |
| kubelet           | Ensures assigned Pods are running on a Node       |
| Container Runtime | Pulls images and manages containers               |

The lab uses `containerd` as the container runtime.

## Important Mental Model

```text
metadata = Who am I?

spec     = What do I want?

status   = What is actually happening?
```

Kubernetes continuously tries to make the observed state match the desired state:

```text
Desired State
    ↓
   spec
    ↓
Kubernetes Controllers
    ↓
Observed State
    ↓
  status
```

This reconciliation process is the foundation of Kubernetes behavior.

## Lab Environment

* Kubernetes distribution: kind
* Control Plane: 1 node
* Worker Nodes: 2 nodes
* Container Runtime: containerd
* Lab Namespace: `myk8s`

The cluster currently contains:

```text
kind-control-plane
kind-worker
kind-worker2
```

## Common Commands

Check cluster Nodes:

```bash
kubectl get nodes -o wide
```

Check Pods in the lab namespace:

```bash
kubectl get pods -n myk8s -o wide
```

Inspect a Kubernetes object:

```bash
kubectl describe <resource> <name> -n myk8s
```

View the complete object definition:

```bash
kubectl get <resource> <name> -n myk8s -o yaml
```

Watch changes in real time:

```bash
kubectl get pods -n myk8s -w
```

View recent namespace events:

```bash
kubectl get events -n myk8s --sort-by=.lastTimestamp
```

## Repository Structure

```text
kubernetes-learning-lab/
│
├── README.md
│
├── 01-pod-fundamentals/
│   ├── README.md
│   └── manifests/
│       ├── pod-nginx.yaml
│       └── pod-bad-nginx.yaml
│
├── 02-deployment-replicaset/
│   ├── README.md
│   └── manifests/
│
├── 03-labels-selectors-service/
│   ├── README.md
│   └── manifests/
│
├── 04-configmap-secret/
│   ├── README.md
│   └── manifests/
│
├── 05-storage/
│   ├── README.md
│   └── manifests/
│
├── 06-ingress/
│   ├── README.md
│   └── manifests/
│
├── 07-rbac-security/
│   ├── README.md
│   └── manifests/
│
└── 08-networkpolicy/
    ├── README.md
    └── manifests/
```

## Lesson Documentation Standard

Each lesson should document:

1. The objective
2. The Kubernetes object or concept
3. The problem it solves
4. The relevant manifest
5. The commands used
6. The expected output
7. What was observed
8. A failure or troubleshooting exercise
9. The Kubernetes components involved
10. The key takeaways
11. The next concept to study

The lesson folder `README.md` is the detailed study note for that topic. This root `README.md` provides the overall roadmap and repository context.

## Current Progress

### Completed

- Lesson 01 — Pod Fundamentals
* Pod basic structure
* Pod lifecycle
* Scheduler role
* kubelet role
* Container runtime role
* Desired state versus observed state
* Pod IP versus Node IP
* `ErrImagePull`
* `ImagePullBackOff`
* Basic Pod troubleshooting
* Using `kubectl get`
* Using `kubectl describe`
* Inspecting Pod events

- Lesson 02 — Deployment and ReplicaSet
* Reconciliation and self-healing
* Scaling workloads
* Labels and selectors
* ReplicaSet ownership
* pod-template-hash
* Rolling updates
* Rollback

### Next

**Lesson 03 — Labels, Selectors, and Service**

## Key Learning Principle

The objective of this repository is not to memorize every Kubernetes field.

The priority is to understand:

```text
What is the object?
        ↓
Why does it exist?
        ↓
What problem does it solve?
        ↓
Which component manages it?
        ↓
What does its spec request?
        ↓
What does its status report?
        ↓
What happens when something fails?
        ↓
How can the failure be diagnosed?
```
