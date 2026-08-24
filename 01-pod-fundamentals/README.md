# Lesson 01 — Pod Fundamentals

## Objective

Understand what a Kubernetes Pod is, how it is created, which Kubernetes components are involved, and how to troubleshoot basic Pod failures.

---

## 1. What is a Pod?

A Pod is the smallest deployable unit in Kubernetes.

A Pod can contain one or more containers.

```text
Pod
└── nginx container
```

In this lab:

```text
my-nginx
└── nginx
```

For production applications, standalone Pods are usually not created directly. Higher-level objects such as Deployments are typically used to manage Pods.

---

## 2. Kubernetes Object vs Kubernetes Component

### Kubernetes Object

An object describes what I want Kubernetes to manage.

Examples:

* Pod
* Deployment
* Service
* ConfigMap
* Secret

For this lesson:

```text
Object = Pod
```

### Kubernetes Components

Components make the desired state happen.

Important components in this lesson:

```text
API Server
Scheduler
kubelet
Container Runtime
```

My cluster uses:

```text
Container Runtime = containerd
```

Mental model:

```text
Object     = WHAT I want
Component  = HOW Kubernetes makes it happen
```

---

## 3. Lab Environment

Cluster:

```text
kind-control-plane
kind-worker
kind-worker2
```

Namespace:

```text
myk8s
```

Check Nodes:

```bash
kubectl get nodes -o wide
```

Check Pods:

```bash
kubectl get pods -n myk8s -o wide
```

---

## 4. Pod Manifest

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

Apply:

```bash
kubectl apply -f manifests/pod-nginx.yaml
```

Verify:

```bash
kubectl get pod my-nginx -n myk8s -o wide
```

Inspect:

```bash
kubectl describe pod my-nginx -n myk8s
```

---

## 5. Basic Pod Structure

The main fields I need to understand are:

```yaml
apiVersion:
kind:
metadata:
spec:
```

### apiVersion

Defines which Kubernetes API is used.

```yaml
apiVersion: v1
```

### kind

Defines the object type.

```yaml
kind: Pod
```

### metadata

Defines the identity of the object.

```yaml
metadata:
  name: my-nginx
  namespace: myk8s
```

Important metadata fields for now:

```text
name
namespace
labels
```

### spec

Defines the desired state.

```yaml
spec:
  containers:
```

For this Pod, the desired state is:

> Run an nginx container.

---

## 6. What Happens After `kubectl apply`

Simplified workflow:

```text
kubectl
   │
   ▼
API Server
   │
   ▼
Pod object created
   │
   ▼
Scheduler
   │
   │ chooses Node
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

Responsibilities:

| Component  | Responsibility                              |
| ---------- | ------------------------------------------- |
| kubectl    | Sends the request                           |
| API Server | Receives and manages Kubernetes API objects |
| Scheduler  | Decides where the Pod should run            |
| kubelet    | Ensures the Pod runs on the assigned Node   |
| containerd | Manages the actual container                |

Simple way to remember:

```text
Scheduler  → WHERE
kubelet    → RUN IT
containerd → CONTAINER
```

---

## 7. Scheduling Result

In this lab, Kubernetes scheduled the Pod on:

```text
kind-worker2
```

Node IP:

```text
172.18.0.2
```

Pod IP:

```text
10.10.0.244
```

Relationship:

```text
kind-worker2
172.18.0.2
    │
    └── my-nginx
        10.10.0.244
```

The Node IP and Pod IP are different.

---

## 8. Desired State vs Observed State

This is one of the most important Kubernetes concepts.

```text
spec   = what I want
status = what Kubernetes currently observes
```

Example:

```yaml
spec:
  containers:
    - image: nginx:latest
```

Desired state:

```text
Run nginx
```

Kubernetes may report:

```yaml
status:
  phase: Running
```

Observed state:

```text
nginx is running
```

Mental model:

```text
Desired State
    ↓
   spec
    ↓
Kubernetes
    ↓
Observed State
    ↓
  status
```

---

## 9. Important Pod Status Information

When troubleshooting, focus on:

```text
Name
Namespace
Node
Status
IP

Containers
  Image
  State
  Ready
  Restart Count

Conditions
  PodScheduled
  ContainersReady
  Ready

Events
```

Do not try to understand every field returned by:

```bash
kubectl get pod my-nginx -n myk8s -o yaml
```

Kubernetes automatically adds many default and internal fields.

---

## 10. Healthy Pod

A healthy Pod should look similar to:

```text
READY   STATUS
1/1     Running
```

`1/1` means:

```text
1 ready container
-----------------
1 total container
```

Important conditions:

```text
PodScheduled       True
ContainersReady    True
Ready              True
```

---

## 11. Broken Image Lab

File:

```text
manifests/pod-bad-nginx.yaml
```

Example:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: my-bad-nginx
  namespace: myk8s

spec:
  containers:
    - name: nginx
      image: nginx:this-image-does-not-exist-12345
```

Apply:

```bash
kubectl apply -f manifests/pod-bad-nginx.yaml
```

Watch:

```bash
kubectl get pod my-bad-nginx -n myk8s -w
```

Expected failure:

```text
ErrImagePull
```

followed by:

```text
ImagePullBackOff
```

---

## 12. Understanding ImagePullBackOff

Failure flow:

```text
Pod created
   │
   ▼
Scheduler selects Node
   │
   ▼
kubelet receives Pod
   │
   ▼
containerd tries to pull image
   │
   ▼
Image does not exist
   │
   ▼
ErrImagePull
   │
   ▼
Retry
   │
   ▼
ImagePullBackOff
```

`ImagePullBackOff` means Kubernetes has failed to pull the image repeatedly and waits before retrying again.

---

## 13. Troubleshooting Workflow

Start with:

```bash
kubectl get pods -n myk8s
```

Then:

```bash
kubectl describe pod <pod-name> -n myk8s
```

Focus on:

```text
Status
Conditions
Events
```

For the broken image example:

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

This tells me:

```text
Scheduling problem?      No
Node problem?            No
Application crash?       No
Image pull problem?      Yes
```

---

## 14. Container Restart vs Pod Recreation

A standalone Pod normally has:

```yaml
restartPolicy: Always
```

If the container crashes:

```text
Container crashes
      ↓
kubelet
      ↓
Restart container
```

But if the Pod itself is deleted:

```bash
kubectl delete pod my-nginx -n myk8s
```

then:

```text
Standalone Pod deleted
       ↓
      Gone
```

The Pod is not automatically recreated because there is no higher-level controller managing it.

This will be covered in Lesson 02 with Deployment and ReplicaSet.

---

## 15. Commands Learned

```bash
kubectl get nodes -o wide

kubectl get pods -n myk8s

kubectl get pods -n myk8s -o wide

kubectl describe pod my-nginx -n myk8s

kubectl get pod my-nginx -n myk8s -o yaml

kubectl get pods -n myk8s -w

kubectl exec -it my-nginx -n myk8s -- /bin/sh

kubectl delete pod my-nginx -n myk8s
```

---

## 16. What I Must Remember

### Pod

```text
Pod = smallest deployable workload unit
```

### Components

```text
API Server  → receives/manages API objects

Scheduler   → decides WHERE the Pod runs

kubelet     → makes sure the Pod runs on the Node

containerd  → manages the container
```

### Object structure

```text
metadata → Who am I?

spec     → What do I want?

status   → What is happening now?
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
Find the failed stage
```

---

## 17. Key Takeaway

Do not memorize every YAML parameter.

Focus on understanding:

```text
What is the object?
        ↓
Why does it exist?
        ↓
Who manages it?
        ↓
Where does it run?
        ↓
What does spec request?
        ↓
What does status report?
        ↓
Where did the lifecycle fail?
```

---

## Next Lesson

**Lesson 02 — Deployment and ReplicaSet**

Next question:

> Why does a standalone Pod disappear when deleted, but a Pod managed by a Deployment gets recreated automatically?

Next relationship:

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
```
