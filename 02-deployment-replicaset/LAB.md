# Lesson 02 Hands-on Lab — Deployment, ReplicaSet, Reconciliation, Rollout, and Rollback

Run commands from the repository root.

## Goal

Create a Deployment, observe the Deployment → ReplicaSet → Pod hierarchy, test self-healing and scaling, then perform a rolling update and rollback.

## Prerequisite

```bash
kubectl get namespace myk8s
```

Expected: `myk8s` is `Active`.

## Step 1 — Start from a clean Deployment

```bash
kubectl delete deployment web -n myk8s --ignore-not-found
kubectl apply -f 02-deployment-replicaset/manifests/deployment-web.yaml
kubectl rollout status deployment/web -n myk8s
```

### Expected result

The rollout should finish successfully.

```bash
kubectl get deployment web -n myk8s
kubectl get rs -n myk8s -l app=web
kubectl get pods -n myk8s -l app=web -o wide
```

Expected shape:

```text
Deployment/web: 1 desired replica
        ↓
1 ReplicaSet
        ↓
1 Running Pod
```

Exact ReplicaSet and Pod suffixes can differ.

## Step 2 — Verify ownership

Capture the current ReplicaSet and Pod names dynamically:

```bash
RS=$(kubectl get rs -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
POD=$(kubectl get pods -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
echo "$RS"
echo "$POD"
```

Inspect:

```bash
kubectl describe rs "$RS" -n myk8s
kubectl describe pod "$POD" -n myk8s
```

### Expected result

The ReplicaSet should show:

```text
Controlled By: Deployment/web
```

The Pod should show:

```text
Controlled By: ReplicaSet/<current-rs-name>
```

## Step 3 — Test self-healing

Record the current Pod:

```bash
OLD_POD=$(kubectl get pods -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
echo "$OLD_POD"
```

Delete it:

```bash
kubectl delete pod "$OLD_POD" -n myk8s
kubectl wait --for=condition=Ready pod -l app=web -n myk8s --timeout=120s
kubectl get pods -n myk8s -l app=web -o wide
```

### Expected result

A new Pod should appear with a different name. The Deployment still has one ready replica.

What this proves:

```text
Desired = 1
Actual  = 0
    ↓
ReplicaSet controller creates replacement
    ↓
Desired = Actual = 1
```

## Step 4 — Scale from 1 to 3 replicas

```bash
kubectl scale deployment web --replicas=3 -n myk8s
kubectl rollout status deployment/web -n myk8s
kubectl get deployment web -n myk8s
kubectl get rs -n myk8s -l app=web
kubectl get pods -n myk8s -l app=web -o wide
```

### Expected result

```text
Deployment READY: 3/3
ReplicaSet DESIRED/CURRENT/READY: 3/3/3
3 Running Pods
```

## Step 5 — Delete one of the three Pods

```bash
POD=$(kubectl get pods -n myk8s -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "$POD" -n myk8s
kubectl wait --for=condition=Ready pod -l app=web -n myk8s --timeout=120s
kubectl get pods -n myk8s -l app=web
```

### Expected result

There should again be three Running Pods. One Pod name should be new.

## Step 6 — Observe Deployment correcting manual ReplicaSet scaling

Get the active ReplicaSet without assuming its hash:

```bash
RS=$(kubectl get rs -n myk8s -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' \
  | awk '$2 > 0 {print $1; exit}')
echo "$RS"
```

Manually request four replicas on the ReplicaSet:

```bash
kubectl scale rs "$RS" --replicas=4 -n myk8s
sleep 3
kubectl get rs "$RS" -n myk8s
kubectl get pods -n myk8s -l app=web
```

### Expected result

The Deployment controller should correct the ReplicaSet back toward three desired replicas. Final steady state should again be three Pods.

If the correction happens too quickly to observe, inspect Deployment Events:

```bash
kubectl describe deployment web -n myk8s
```

Look for a scale-down event.

## Step 7 — Optional advanced selector experiment

Get the active ReplicaSet's template hash:

```bash
RS=$(kubectl get rs -n myk8s -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' \
  | awk '$2 > 0 {print $1; exit}')
HASH=$(kubectl get rs "$RS" -n myk8s -o jsonpath='{.metadata.labels.pod-template-hash}')
echo "$HASH"
```

Create an extra standalone Pod matching the ReplicaSet labels:

```bash
kubectl run extra-web \
  --image=nginx:latest \
  --restart=Never \
  -n myk8s \
  --labels="app=web,pod-template-hash=$HASH"
```

Wait briefly and inspect:

```bash
sleep 3
kubectl get pods -n myk8s -l app=web
kubectl describe rs "$RS" -n myk8s
```

### Expected result

The ReplicaSet should maintain a population of three matching Pods and may remove the excess matching Pod. Exact timing can vary.

Important: this experiment demonstrates selector-based population management. Do not assume ownership/adoption behavior unless you explicitly verify `ownerReferences`.

## Step 8 — Rolling update to nginx:alpine

```bash
kubectl set image deployment/web nginx=nginx:alpine -n myk8s
kubectl rollout status deployment/web -n myk8s
kubectl get rs -n myk8s -l app=web
kubectl get pods -n myk8s -l app=web
```

### Expected result

A new ReplicaSet should exist with three ready replicas. The previous ReplicaSet should remain with zero replicas.

Verify the running image:

```bash
kubectl get deployment web -n myk8s -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected:

```text
nginx:alpine
```

## Step 9 — Inspect rollout history

```bash
kubectl rollout history deployment/web -n myk8s
```

### Expected result

At least two revisions should be visible after the image update.

## Step 10 — Roll back

```bash
kubectl rollout undo deployment/web -n myk8s
kubectl rollout status deployment/web -n myk8s
kubectl get rs -n myk8s -l app=web
```

Verify the image:

```bash
kubectl get deployment web -n myk8s -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Expected result

```text
nginx:latest
```

The older ReplicaSet should become active again with three replicas.

## Cleanup and required end state for Lesson 03

Remove the optional standalone Pod if it still exists:

```bash
kubectl delete pod extra-web -n myk8s --ignore-not-found
```

Ensure the Deployment has three replicas:

```bash
kubectl scale deployment web --replicas=3 -n myk8s
kubectl rollout status deployment/web -n myk8s
kubectl get pods -n myk8s -l app=web
```

### Expected result

Three nginx Pods are Running and the Deployment image is `nginx:latest`.

Continue with [Lesson 03 Hands-on Lab](../03-labels-selectors-service/LAB.md).
