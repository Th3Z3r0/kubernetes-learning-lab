# Lesson 02 — Deployment, ReplicaSet, Reconciliation, Rolling Update, and Rollback

## Objective

Understand how Kubernetes manages application workloads using:

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
    ↓
Container
```

This lesson focuses on:

* Why standalone Pods are not normally used for production workloads
* What a Deployment does
* What a ReplicaSet does
* How reconciliation works
* How scaling works
* How labels and selectors connect objects
* How Kubernetes replaces deleted Pods
* How rolling updates work
* Why a new ReplicaSet appears after changing the Pod template
* How Deployment rollback works

---

# 1. Why Use a Deployment?

In Lesson 01, I created a standalone Pod:

```text
Pod
└── nginx container
```

If I deleted that Pod:

```bash
kubectl delete pod my-nginx -n myk8s
```

the Pod disappeared permanently.

There was no controller responsible for recreating it.

With a Deployment:

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
```

Kubernetes continuously maintains the desired application state.

---

# 2. Deployment, ReplicaSet, and Pod Responsibilities

The objects have different responsibilities.

## Deployment

A Deployment manages:

* Desired replica count
* Pod template
* Application rollout
* Rolling updates
* ReplicaSet lifecycle
* Rollback history

Mental model:

```text
Deployment
"Which version should run?"
"How many replicas?"
"How should updates happen?"
```

## ReplicaSet

A ReplicaSet mainly manages:

> The desired number of Pods matching its selector.

Mental model:

```text
ReplicaSet
"I need exactly N matching Pods."
```

## Pod

A Pod represents one workload instance.

```text
Pod
└── Container
    └── Application Process
```

## Overall Relationship

```text
Deployment
│
│ manages rollout and ReplicaSets
│
▼
ReplicaSet
│
│ maintains desired Pod count
│
▼
Pod
│
│ runs workload
│
▼
Container
```

---

# 3. Creating the Deployment

The Deployment was created with:

```bash
kubectl create deployment web \
  --image=nginx:latest \
  -n myk8s
```

Check the Deployment:

```bash
kubectl get deployment -n myk8s
```

Check ReplicaSets:

```bash
kubectl get rs -n myk8s
```

Check Pods:

```bash
kubectl get pods -n myk8s -o wide
```

Kubernetes automatically created:

```text
Deployment/web
      │
      ▼
ReplicaSet/web-799996dd5c
      │
      ▼
Pod/web-799996dd5c-xxxxx
```

I created only the Deployment.

Kubernetes created the ReplicaSet and Pod underneath it.

---

# 4. Ownership Relationship

The hierarchy can be verified using `kubectl describe`.

For the ReplicaSet:

```bash
kubectl describe rs web-799996dd5c -n myk8s
```

The output showed:

```text
Controlled By: Deployment/web
```

For a Pod managed by that ReplicaSet:

```bash
kubectl describe pod <pod-name> -n myk8s
```

The Pod is controlled by the ReplicaSet.

Mental model:

```text
Deployment/web
      │
      │ owns/manages
      ▼
ReplicaSet/web-799996dd5c
      │
      │ owns/manages
      ▼
Pods
```

---

# 5. Self-Healing Experiment

The Deployment initially had:

```text
Desired replicas = 1
Actual replicas  = 1
```

I deleted its Pod:

```bash
kubectl delete pod <pod-name> -n myk8s
```

Kubernetes automatically created a new Pod.

Example:

```text
Old Pod:
web-799996dd5c-v9lxc

Deleted
   ↓

New Pod:
web-799996dd5c-rkl9s
```

The replacement Pod received:

* A new Pod name
* A new Pod IP
* Potentially a different Node

Example:

```text
Old Pod
IP:   10.10.2.251
Node: kind-worker

New Pod
IP:   10.10.0.242
Node: kind-worker2
```

Important lesson:

> Kubernetes did not restore the old Pod. It created a new Pod to restore the desired state.

---

# 6. Reconciliation

Reconciliation is one of the most important Kubernetes concepts.

The ReplicaSet continuously compares:

```text
Desired State
vs
Actual State
```

Example:

```text
Desired = 1
Actual  = 0
```

The controller detects the mismatch:

```text
Desired = 1
Actual  = 0
    │
    ▼
ReplicaSet Controller
    │
    ▼
Create 1 Pod
    │
    ▼
Desired = 1
Actual  = 1
```

When they match:

```text
Desired = Actual
```

no corrective action is required.

---

# 7. Scaling From 1 to 3 Pods

The Deployment was scaled using:

```bash
kubectl scale deployment web \
  --replicas=3 \
  -n myk8s
```

Immediately after scaling, the Deployment briefly showed:

```text
READY
1/3
```

Then later:

```text
READY
3/3
```

This demonstrates that Kubernetes changes are not always instantaneous.

The desired state changed immediately:

```text
Desired replicas = 3
```

but the actual state needed time to catch up.

The ReplicaSet eventually showed:

```text
DESIRED   CURRENT   READY
3         3         3
```

Mental model:

```text
Deployment
replicas = 3
     │
     ▼
ReplicaSet
desired = 3
     │
     ├── Pod A
     ├── Pod B
     └── Pod C
```

---

# 8. ReplicaSet Recreates Deleted Pods

After scaling to 3 replicas:

```text
Pod A
Pod B
Pod C
```

I deleted one Pod:

```bash
kubectl delete pod <pod-name> -n myk8s
```

For a short time:

```text
Desired = 3
Actual  = 2
```

The ReplicaSet controller detected the mismatch and created a replacement:

```text
Desired = 3
Actual  = 2
      ↓
ReplicaSet Controller
      ↓
Create 1 Pod
      ↓
Actual = 3
```

Final state:

```text
3 Running Pods
```

---

# 9. Labels and Selectors

The Deployment uses:

```yaml
selector:
  matchLabels:
    app: web
```

The Pod template gives new Pods:

```yaml
metadata:
  labels:
    app: web
```

Therefore:

```text
Selector
app=web
    │
    ▼
matches
    │
    ▼
Pods with:
app=web
```

This can be verified with:

```bash
kubectl get pods -n myk8s \
  -l app=web \
  --show-labels
```

Example output:

```text
app=web,pod-template-hash=799996dd5c
```

Important lesson:

> Kubernetes does not primarily identify application Pods by their names. It uses labels and selectors.

---

# 10. Core Deployment Manifest

The live Deployment YAML contained many fields, but the important structure is:

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: web
  namespace: myk8s

spec:
  replicas: 3

  selector:
    matchLabels:
      app: web

  template:
    metadata:
      labels:
        app: web

    spec:
      containers:
        - name: nginx
          image: nginx:latest
```

Important fields:

```text
apiVersion
kind
metadata.name

spec.replicas

spec.selector

spec.template.metadata.labels

spec.template.spec.containers
```

---

# 11. Understanding the Pod Template

A Deployment does not directly contain running containers.

It contains a **Pod template**.

```text
Deployment
    │
    └── Pod Template
          │
          ├── labels
          └── container specification
```

Example:

```yaml
template:
  metadata:
    labels:
      app: web

  spec:
    containers:
      - name: nginx
        image: nginx:latest
```

This means:

> When Kubernetes creates Pods for this Deployment, create them using this template.

---

# 12. pod-template-hash

The Pods contained:

```text
pod-template-hash=799996dd5c
```

The ReplicaSet name was:

```text
web-799996dd5c
```

These values are related.

Mental model:

```text
Pod Template Version
       │
       ▼
pod-template-hash
       │
       ▼
ReplicaSet
       │
       ▼
Pods with same hash
```

Example:

```text
ReplicaSet:
web-799996dd5c

Pods:
app=web
pod-template-hash=799996dd5c
```

This becomes especially important during rolling updates.

---

# 13. Manual ReplicaSet Scale Experiment

The Deployment wanted:

```text
replicas = 3
```

I manually changed the ReplicaSet to:

```text
replicas = 4
```

using:

```bash
kubectl scale rs web-799996dd5c \
  --replicas=4 \
  -n myk8s
```

The watch showed approximately:

```text
DESIRED   CURRENT   READY

3         3         3
4         3         3
3         3         3
3         4         3
3         3         3
```

This showed two reconciliation loops.

First:

```text
Deployment desired = 3

ReplicaSet desired = 4
        │
        ▼
Deployment Controller
        │
        ▼
ReplicaSet desired corrected to 3
```

Then:

```text
ReplicaSet desired = 3
Actual Pods        = 4
        │
        ▼
ReplicaSet Controller
        │
        ▼
Delete 1 Pod
```

The Deployment Events showed:

```text
Scaled down replica set web-799996dd5c from 4 to 3
```

Important lesson:

> If a ReplicaSet is owned by a Deployment, the Deployment is the higher-level source of truth.

Do not normally scale the ReplicaSet directly.

---

# 14. Nested Reconciliation Loops

This experiment showed that Kubernetes has multiple controllers working at different levels.

```text
Deployment
spec.replicas = 3
       │
       ▼
Deployment Controller
       │
       ▼
ReplicaSet
desired replicas = 3
       │
       ▼
ReplicaSet Controller
       │
       ▼
3 Pods
```

Therefore:

```text
Deployment Controller
        │
        ▼
ReplicaSet
        │
        ▼
ReplicaSet Controller
        │
        ▼
Pods
```

Each controller watches its own desired and actual state.

---

# 15. Extra Pod Matching the ReplicaSet Selector

The ReplicaSet selector was:

```text
app=web
pod-template-hash=799996dd5c
```

It was verified with:

```bash
kubectl get rs web-799996dd5c \
  -n myk8s \
  -o jsonpath='{.spec.selector.matchLabels}{"\n"}'
```

Output:

```text
{"app":"web","pod-template-hash":"799996dd5c"}
```

The hash was stored in a variable:

```bash
HASH=$(kubectl get rs web-799996dd5c \
  -n myk8s \
  -o jsonpath='{.metadata.labels.pod-template-hash}')
```

Then:

```bash
echo $HASH
```

returned:

```text
799996dd5c
```

---

# 16. Creating an Extra Matching Pod

A standalone Pod was created with the same labels:

```bash
kubectl run extra-web \
  --image=nginx:latest \
  --restart=Never \
  -n myk8s \
  --labels="app=web,pod-template-hash=$HASH"
```

The watch showed:

```text
extra-web Pending
extra-web Terminating
extra-web ContainerStatusUnknown
```

The ReplicaSet Event later showed:

```text
SuccessfulDelete
Deleted pod: extra-web
```

Why?

The ReplicaSet wanted:

```text
Desired matching Pods = 3
```

but now found:

```text
Matching Pods = 4
```

because `extra-web` matched its selector.

So:

```text
Desired = 3
Actual matching Pods = 4
        │
        ▼
ReplicaSet Controller
        │
        ▼
Delete excess Pod
        │
        ▼
Actual = 3
```

Important lesson:

> ReplicaSets care about Pods matching their selector, not specific Pod names.

---

# 17. ReplicaSet Does Not Primarily Care About Pod Names

These names:

```text
web-799996dd5c-4b6hl
web-799996dd5c-792dq
web-799996dd5c-tcckr
```

are not the main mechanism the ReplicaSet uses to manage Pods.

What matters more is:

```text
app=web
pod-template-hash=799996dd5c
```

Mental model:

```text
ReplicaSet selector
       │
       ▼
Matching labels
       │
       ▼
Managed Pod population
```

---

# 18. Rolling Update

The Deployment image was changed from:

```text
nginx:latest
```

to:

```text
nginx:alpine
```

using:

```bash
kubectl set image deployment/web \
  nginx=nginx:alpine \
  -n myk8s
```

This changed:

```text
Deployment.spec.template
```

A Pod template change causes a new ReplicaSet.

---

# 19. New Pod Template = New ReplicaSet

Before:

```text
Pod Template v1
nginx:latest
       │
       ▼
Hash:
799996dd5c
       │
       ▼
ReplicaSet:
web-799996dd5c
```

After:

```text
Pod Template v2
nginx:alpine
       │
       ▼
Hash:
68dfbdbf65
       │
       ▼
ReplicaSet:
web-68dfbdbf65
```

Important relationship:

```text
Pod template changes
       ↓
New pod-template-hash
       ↓
New ReplicaSet
```

---

# 20. Rolling Update Intermediate State

During the update:

```bash
kubectl get rs -n myk8s
```

showed:

```text
NAME             DESIRED   CURRENT   READY

web-68dfbdbf65   2         2         1
web-799996dd5c   2         2         2
```

This means both versions temporarily existed at the same time.

Conceptually:

```text
Old Version = A
New Version = B

A A A
  ↓
A A B
  ↓
A B B
  ↓
B B B
```

The exact number of Pods during each stage depends on the Deployment rollout strategy.

---

# 21. RollingUpdate Strategy

The Deployment used:

```text
StrategyType: RollingUpdate
```

with:

```text
25% max unavailable
25% max surge
```

For this small 3-replica deployment, Kubernetes could temporarily create an extra Pod during the transition.

Conceptually:

```text
Normal replicas = 3

During rollout:
possibly 4 total Pods temporarily
```

This is different from an accidental extra Pod.

Manual extra Pod:

```text
Unwanted
    ↓
Controller removes it
```

RollingUpdate surge Pod:

```text
Intentional
    ↓
Deployment uses it during rollout
```

---

# 22. Deployment Events During Rolling Update

The Deployment Events showed:

```text
Scaled up new ReplicaSet from 0 to 1

Scaled down old ReplicaSet from 3 to 2

Scaled up new ReplicaSet from 1 to 2

Scaled down old ReplicaSet from 2 to 1

Scaled up new ReplicaSet from 2 to 3

Scaled down old ReplicaSet from 1 to 0
```

This can be visualized as:

```text
Old RS     New RS

3            0
3            1
2            1
2            2
1            2
1            3
0            3
```

The Deployment controller coordinated this process.

---

# 23. Final State After Rolling Update

After the rollout finished:

```text
web-68dfbdbf65   3   3   3
web-799996dd5c   0   0   0
```

Meaning:

```text
Deployment/web
│
├── Old ReplicaSet
│   web-799996dd5c
│   nginx:latest
│   replicas = 0
│
└── New ReplicaSet
    web-68dfbdbf65
    nginx:alpine
    replicas = 3
```

The old ReplicaSet remained.

This allows Kubernetes to maintain rollout history and support rollback.

---

# 24. Rollout History

The rollout history was checked with:

```bash
kubectl rollout history deployment/web -n myk8s
```

Example:

```text
REVISION
1
2
```

Conceptually:

```text
Revision 1
nginx:latest

Revision 2
nginx:alpine
```

The Deployment tracks rollout revisions.

---

# 25. Rollback

Rollback was performed using:

```bash
kubectl rollout undo deployment/web -n myk8s
```

Then:

```bash
kubectl rollout status deployment/web -n myk8s
```

The Deployment returned to the previous Pod template.

Final ReplicaSet state:

```text
web-68dfbdbf65   0   0   0
web-799996dd5c   3   3   3
```

Meaning:

```text
nginx:alpine
0 replicas

nginx:latest
3 replicas
```

---

# 26. Rollback Is Also a Rolling Transition

The watch showed the rollback happening gradually.

New Pods from the previous ReplicaSet appeared:

```text
Pending
    ↓
ContainerCreating
    ↓
Running
```

while Alpine Pods moved through:

```text
Running
    ↓
Terminating
    ↓
Completed
    ↓
Removed
```

Conceptually:

```text
B B B
  ↓
A B B
  ↓
A A B
  ↓
A A A
```

Where:

```text
A = nginx:latest
B = nginx:alpine
```

Important lesson:

> Rollback does not normally kill all current Pods first and then start the previous version.

It uses the Deployment rollout mechanism.

---

# 27. Why Keep Old ReplicaSets?

After a rolling update, Kubernetes may keep:

```text
Old ReplicaSet
replicas = 0
```

instead of deleting it immediately.

This provides:

```text
Rollout history
Rollback capability
Previous Pod templates
```

The Deployment property:

```text
revisionHistoryLimit
```

controls how many old ReplicaSets are retained.

This can be studied in more detail later.

---

# 28. Deployment vs ReplicaSet

The main difference is now clear.

## ReplicaSet

Main responsibility:

```text
Maintain N matching Pods
```

Example:

```text
Desired = 3
Actual  = 2
    ↓
Create 1
```

or:

```text
Desired = 3
Actual  = 4
    ↓
Delete 1
```

## Deployment

Main responsibility:

```text
Manage application deployment lifecycle
```

Including:

```text
Replica count
Pod template
ReplicaSets
Rolling updates
Revision history
Rollback
```

Mental model:

```text
Deployment
"Which version and how should it be deployed?"
        │
        ▼
ReplicaSet
"How many Pods?"
        │
        ▼
Pod
"Run this workload."
```

---

# 29. Important Commands Learned

## Deployment

```bash
kubectl create deployment web \
  --image=nginx:latest \
  -n myk8s
```

```bash
kubectl get deployment -n myk8s
```

```bash
kubectl describe deployment web -n myk8s
```

```bash
kubectl get deployment web -n myk8s -o yaml
```

---

## ReplicaSet

```bash
kubectl get rs -n myk8s
```

```bash
kubectl describe rs web-799996dd5c -n myk8s
```

```bash
kubectl get rs -n myk8s --show-labels
```

---

## Pods

```bash
kubectl get pods -n myk8s -l app=web
```

```bash
kubectl get pods -n myk8s \
  -l app=web \
  --show-labels
```

```bash
kubectl get pods -n myk8s \
  -l app=web \
  -o wide
```

```bash
kubectl get pods -n myk8s \
  -l app=web \
  -w
```

---

## Scaling

```bash
kubectl scale deployment web \
  --replicas=3 \
  -n myk8s
```

---

## Image Update

```bash
kubectl set image deployment/web \
  nginx=nginx:alpine \
  -n myk8s
```

---

## Rollout

```bash
kubectl rollout status deployment/web -n myk8s
```

```bash
kubectl rollout history deployment/web -n myk8s
```

```bash
kubectl rollout undo deployment/web -n myk8s
```

---

# 30. What I Must Remember

## Hierarchy

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
    ↓
Container
```

## Responsibilities

```text
Deployment
→ application rollout and version management

ReplicaSet
→ maintains desired Pod count

Pod
→ workload instance

Container
→ application process
```

## Reconciliation

```text
Desired State
      ↓
Controller
      ↓
Compare
      ↓
Actual State
      ↓
Mismatch?
      ↓
Correct it
```

## Labels and Selectors

```text
Selector
app=web
    ↓
matches
    ↓
Pods carrying:
app=web
```

## Pod Template

```text
Deployment
    ↓
spec.template
    ↓
Pod blueprint
```

## Template Change

```text
Pod template changes
       ↓
New hash
       ↓
New ReplicaSet
```

## Rolling Update

```text
Old ReplicaSet
       ↓
gradual transition
       ↓
New ReplicaSet
```

## Rollback

```text
Current ReplicaSet
       ↓
Deployment rollback
       ↓
Previous ReplicaSet scaled up
```

---

# 31. Key Troubleshooting View

When troubleshooting a Deployment:

```text
Deployment
    ↓
ReplicaSet
    ↓
Pod
    ↓
Container
```

Check each layer.

Start with:

```bash
kubectl get deployment -n myk8s
```

Then:

```bash
kubectl get rs -n myk8s
```

Then:

```bash
kubectl get pods -n myk8s -l app=web
```

Then inspect:

```bash
kubectl describe deployment web -n myk8s
```

```bash
kubectl describe rs <replicaset-name> -n myk8s
```

```bash
kubectl describe pod <pod-name> -n myk8s
```

Mental troubleshooting flow:

```text
Deployment healthy?
      ↓
ReplicaSet correct?
      ↓
Desired vs current replicas?
      ↓
Pods running?
      ↓
Containers healthy?
      ↓
Events
```

---

# 32. Lesson 02 Mental Model

The most important diagram from this lesson:

```text
                Deployment/web
                replicas = 3
                     │
                     │ manages
                     ▼
              ReplicaSet
              desired = 3
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
        Pod A      Pod B      Pod C
          │          │          │
          ▼          ▼          ▼
        nginx      nginx      nginx
```

During a rolling update:

```text
                   Deployment
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
        Old ReplicaSet       New ReplicaSet
        nginx:latest         nginx:alpine
             │                   │
             ▼                   ▼
          old Pods            new Pods
```

---

# 33. Main Takeaways

I should not try to memorize every Deployment field.

I should understand:

```text
Why does Deployment exist?

What does ReplicaSet do?

Who recreates deleted Pods?

What does replicas mean?

How does reconciliation work?

How do labels and selectors connect objects?

What is a Pod template?

Why does changing the Pod template create a new ReplicaSet?

Why are old ReplicaSets kept?

How does rolling update work?

How does rollback work?
```

The most important concept is:

> Kubernetes controllers continuously reconcile actual state toward desired state.

---

# Next Lesson

## Lesson 03 — Labels, Selectors, and Service

The next problem to solve is:

```text
Pods are disposable.

Pod names change.

Pod IP addresses change.

Pods can move between Nodes.
```

So:

> How can another application or client reliably reach the web application?

The next relationship will be:

```text
Client
   ↓
Service
   ↓
Selector: app=web
   ↓
┌──────┬──────┬──────┐
▼      ▼      ▼
Pod A  Pod B  Pod C
```

This introduces:

* Labels
* Selectors
* Service
* ClusterIP
* Stable application access
* Basic Kubernetes service discovery
