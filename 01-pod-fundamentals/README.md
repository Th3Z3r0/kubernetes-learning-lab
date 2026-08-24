# Lesson 01 — Kubernetes Pod Fundamentals

## Learning Objectives

After completing this lab, I should understand:

* What a Kubernetes **Pod** is
* The difference between a Kubernetes **object** and a Kubernetes **component**
* What happens after running `kubectl apply`
* How Kubernetes decides which Node runs a Pod
* The roles of the **API Server, Scheduler, kubelet, and container runtime**
* The difference between **desired state (`spec`)** and **observed state (`status`)**
* How to troubleshoot a Pod using `kubectl get` and `kubectl describe`
* What `ErrImagePull` and `ImagePullBackOff` mean

---

# 1. What is a Pod?

A **Pod** is the smallest deployable unit in Kubernetes.

A Pod contains one or more containers.

```text
Pod
└── Container
    └── nginx
```

In this lab:

```text
my-nginx Pod
└── nginx container
```

Normally, applications should not be managed using standalone Pods in production. Higher-level objects such as **Deployments** are normally used to manage Pods.

We will learn why in Lesson 02.

---

# 2. Kubernetes Object vs Component

This distinction is important.

## Kubernetes Object

An object describes **what I want Kubernetes to manage**.

Examples:

```text
Pod
Deployment
Service
ConfigMap
Secret
```

For this lesson:

```text
Object = Pod
```

## Kubernetes Components

Components are parts of Kubernetes that make the desired state happen.

Important components in this lesson:

```text
kube-apiserver
scheduler
kubelet
container runtime
```

My cluster uses:

```text
containerd
```

A useful way to remember this:

> **Object = WHAT I want**
> **Component = HOW Kubernetes makes it happen**

---

# 3. My Lab Environment

The lab uses a kind Kubernetes cluster with three Nodes:

```text
kind-control-plane
kind-worker
kind-worker2
```

Cluster architecture:

```text
Kubernetes Cluster
│
├── kind-control-plane
│
├── kind-worker
│
└── kind-worker2
```

Namespace used for the lab:

```text
myk8s
```

Check the Nodes:

```bash
kubectl get nodes -o wide
```

Check Pods:

```bash
kubectl get pods -n myk8s -o wide
```

---

# 4. Basic Pod Manifest

File:

```text
manifests/pod-nginx.yaml
```

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: my-nginx
  namespace: myk8s

spec:
  containers:
    - name: nginx
      image: nginx:latest
```

Apply it:

```bash
kubectl apply -f manifests/pod-nginx.yaml
```

Check the Pod:

```bash
kubectl get pod my-nginx -n myk8s -o wide
```

Inspect it:

```bash
kubectl describe pod my-nginx -n myk8s
```

---

# 5. Mandatory Pod Manifest Concepts

I do **not** need to memorize every Pod parameter.

For now, I should understand this basic structure:

```yaml
apiVersion:
kind:
metadata:
spec:
```

### `apiVersion`

```yaml
apiVersion: v1
```

Defines which Kubernetes API is used for the object.

### `kind`

```yaml
kind: Pod
```

Defines the type of Kubernetes object.

### `metadata`

```yaml
metadata:
  name: my-nginx
  namespace: myk8s
```

Identifies the object.

Important metadata fields to learn first:

```text
name
namespace
labels
```

### `spec`

```yaml
spec:
  containers:
```

Describes the **desired state**.

For this Pod:

> I want Kubernetes to run an nginx container.

---

# 6. What Happens After `kubectl apply`?

When I run:

```bash
kubectl apply -f manifests/pod-nginx.yaml
```

the simplified workflow is:

```text
kubectl
   │
   ▼
API Server
   │
   ▼
Pod desired state recorded
   │
   ▼
Scheduler
   │
   │ selects a Node
   ▼
Worker Node
   │
   ▼
kubelet
   │
   ▼
containerd
   │
   ▼
nginx container
```

The important responsibilities are:

| Component  | Main Responsibility                             |
| ---------- | ----------------------------------------------- |
| `kubectl`  | Sends my request to Kubernetes                  |
| API Server | Entry point for Kubernetes API operations       |
| Scheduler  | Decides **WHERE** an unscheduled Pod should run |
| kubelet    | Makes sure the Pod runs on its assigned Node    |
| containerd | Manages the actual container                    |

A useful shortcut:

```text
Scheduler → WHERE?

kubelet → RUN IT

containerd → CONTAINER
```

---

# 7. Scheduler

In my experiment, Kubernetes selected:

```text
kind-worker2
```

The Pod showed:

```text
Node: kind-worker2
```

The Event showed:

```text
Successfully assigned myk8s/my-nginx to kind-worker2
```

Therefore:

> `kubectl` did not choose the Worker Node.

The **Kubernetes Scheduler** selected the Node.

After scheduling, the Pod contains information similar to:

```yaml
spec:
  nodeName: kind-worker2
```

---

# 8. kubelet

After the Scheduler assigns the Pod to a Node, the **kubelet** on that Node becomes responsible for making the Pod run.

```text
Scheduler
    │
    │ assigns Pod
    ▼
kind-worker2
    │
    ▼
kubelet
    │
    ▼
container runtime
```

The kubelet works with the container runtime to create and run containers.

My cluster uses:

```text
containerd
```

---

# 9. Pod IP vs Node IP

In my lab:

```text
Node:
kind-worker2

Node IP:
172.18.0.2

Pod IP:
10.10.0.244
```

The relationship is:

```text
kind-worker2
172.18.0.2
     │
     └── my-nginx
           10.10.0.244
```

The **Node IP and Pod IP are different**.

Kubernetes networking and how Pods receive IP addresses will be covered in a later lesson.

---

# 10. Desired State vs Actual State

One of the most important Kubernetes concepts is:

```text
spec   = what I WANT
status = what Kubernetes OBSERVES
```

Example:

```yaml
spec:
  containers:
    - image: nginx:latest
```

means:

> I want nginx to run.

Kubernetes may report:

```yaml
status:
  phase: Running
```

meaning the workload is currently running.

Conceptually:

```text
Desired State
    SPEC
      │
      ▼
 Kubernetes
      │
      ▼
Observed State
    STATUS
```

Kubernetes continuously works toward making the actual state match the desired state.

---

# 11. Important Pod Status Information

When troubleshooting a Pod, I should initially focus on:

```text
Name
Namespace
Node
Status
IP

Containers:
  Image
  State
  Ready
  Restart Count

Conditions:
  Ready
  ContainersReady
  PodScheduled

Events
```

I do **not** need to understand every field returned by:

```bash
kubectl get pod my-nginx -o yaml
```

---

# 12. Healthy Pod

A healthy Pod may show:

```text
READY   STATUS
1/1     Running
```

`1/1` means:

```text
1 ready container
─────────────────
1 total container
```

Important conditions may show:

```text
PodScheduled       True
ContainersReady    True
Ready              True
```

This tells me:

```text
Scheduled        ✓
Container started ✓
Container ready   ✓
Pod ready         ✓
```

---

# 13. Broken Image Lab

File:

```text
manifests/pod-bad-nginx.yaml
```

The Pod intentionally uses an invalid image:

```yaml
image: nginx:this-image-does-not-exist-12345
```

Apply it:

```bash
kubectl apply -f manifests/pod-bad-nginx.yaml
```

Watch the Pod:

```bash
kubectl get pod my-bad-nginx -n myk8s -w
```

The Pod eventually reports:

```text
ErrImagePull
```

and then:

```text
ImagePullBackOff
```

---

# 14. Understanding `ImagePullBackOff`

The Pod creation workflow was:

```text
Pod submitted
     │
     ▼
Scheduler selected Node        ✓
     │
     ▼
kubelet received Pod           ✓
     │
     ▼
containerd tried image pull
     │
     ▼
Image not found                ✗
     │
     ▼
ErrImagePull
     │
     ▼
Retry
     │
     ▼
Failure again
     │
     ▼
ImagePullBackOff
```

`ImagePullBackOff` does **not** mean Kubernetes stopped permanently.

It means repeated image pulls failed and Kubernetes is backing off before retrying again.

---

# 15. Troubleshooting Method

When an application Pod is not running, start with:

```bash
kubectl get pods -n myk8s
```

Then:

```bash
kubectl describe pod <pod-name> -n myk8s
```

Pay special attention to:

```text
Status
Conditions
Events
```

For the broken nginx Pod, Events showed:

```text
Scheduled
   ↓
Pulling
   ↓
Failed
   ↓
ErrImagePull
   ↓
BackOff
   ↓
ImagePullBackOff
```

This allowed me to determine:

```text
Scheduling problem?      No
Node selection problem?  No
Application crash?       No
Image retrieval problem? YES
```

The important lesson is:

> **Troubleshoot the Kubernetes lifecycle and identify which stage failed instead of randomly restarting components.**

---

# 16. Container Restart vs Pod Recreation

A standalone Pod has:

```yaml
restartPolicy: Always
```

by default.

This means if the **container process fails**, kubelet can restart the container.

```text
Pod
└── nginx crashes
       │
       ▼
     kubelet
       │
       ▼
restart container
```

However, if I delete the standalone Pod itself:

```bash
kubectl delete pod my-nginx -n myk8s
```

the Pod does **not** automatically return.

```text
Standalone Pod deleted
       │
       ▼
     Gone
```

There is no higher-level controller maintaining the desired number of Pods.

This is one reason production applications normally use a **Deployment** instead of creating standalone Pods.

---

# 17. Fields Kubernetes Adds Automatically

My small manifest became a much larger object when running:

```bash
kubectl get pod my-nginx -n myk8s -o yaml
```

Kubernetes automatically added/defaulted fields such as:

```text
uid
resourceVersion
generation
creationTimestamp
nodeName
restartPolicy
schedulerName
serviceAccountName
dnsPolicy
terminationGracePeriodSeconds
status
conditions
containerStatuses
podIP
hostIP
```

I do **not** need to manually specify all of these.

A useful rule:

```text
My manifest
    │
    ├── What I explicitly require
    │
    ▼
Kubernetes API
    │
    ├── defaults
    ├── generated information
    └── observed status
    │
    ▼
Full Kubernetes Object
```

---

# 18. What I Must Remember From Lesson 01

### Objects

```text
Pod = smallest deployable Kubernetes workload unit
```

### Components

```text
API Server  → API entry point

Scheduler   → decides WHERE the Pod runs

kubelet     → ensures the Pod runs on the assigned Node

containerd  → manages the actual container
```

### Object structure

```text
metadata → Who am I?

spec     → What do I want?

status   → What is actually happening?
```

### Troubleshooting

```text
kubectl get pods
       ↓
kubectl describe pod
       ↓
Conditions
       ↓
Events
       ↓
Find which lifecycle stage failed
```

### Important distinction

```text
Container fails
     ↓
kubelet can restart container

Standalone Pod deleted
     ↓
Pod is NOT automatically recreated
```

---

# 19. Commands Learned

```bash
# View Nodes
kubectl get nodes -o wide

# View Pods
kubectl get pods -n myk8s
kubectl get pods -n myk8s -o wide

# Inspect a Pod
kubectl describe pod my-nginx -n myk8s

# View the complete Kubernetes object
kubectl get pod my-nginx -n myk8s -o yaml

# Watch Pod changes
kubectl get pods -n myk8s -w

# Execute a command inside a container
kubectl exec -it my-nginx -n myk8s -- /bin/sh

# Delete a Pod
kubectl delete pod my-nginx -n myk8s
```

---

# 20. Lesson 01 Mental Model

The most important diagram from this lesson:

```text
                    Kubernetes Cluster

                        Control Plane
                             │
kubectl ──► API Server ──► Scheduler
                             │
                             │ selects Node
                             ▼
                       kind-worker2
                             │
                          kubelet
                             │
                        containerd
                             │
                             ▼
                         my-nginx
                             │
                         nginx container
```

And the most important Kubernetes concept:

```text
        DESIRED STATE
             spec
              │
              ▼
         Kubernetes
              │
        reconciliation
              │
              ▼
        OBSERVED STATE
            status
```

---

## Next Lesson

**Lesson 02 — Deployment and ReplicaSet**

The next question to answer is:

> If Kubernetes is designed for self-healing, why did my standalone Pod not come back after I deleted it?

We will learn:

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
```

and introduce one of the most important concepts in Kubernetes:

**Controllers and reconciliation.**
