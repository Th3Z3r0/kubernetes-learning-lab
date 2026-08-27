# Lesson 01 Hands-on Lab — Pod Fundamentals

Run commands from the repository root.

## Goal

Create a healthy standalone Pod, inspect it, reproduce `ImagePullBackOff`, and prove that a standalone Pod is not recreated after deletion.

## Prerequisite

```bash
kubectl get namespace myk8s
```

Expected: namespace `myk8s` is `Active`.

## Step 1 — Create the nginx Pod

```bash
kubectl apply -f 01-pod-fundamentals/manifests/pod-nginx.yaml
kubectl get pod my-nginx -n myk8s -w
```

Stop the watch with `Ctrl+C` after the Pod reaches `Running`.

### Expected result

Typical lifecycle:

```text
Pending → ContainerCreating → Running
```

Verify:

```bash
kubectl get pod my-nginx -n myk8s -o wide
```

Expected shape:

```text
READY   STATUS    RESTARTS
1/1     Running   0
```

A Node and Pod IP should be assigned. Exact values can differ.

## Step 2 — Inspect the Pod

```bash
kubectl describe pod my-nginx -n myk8s
```

### Expected result

Confirm:

```text
Status: Running
Ready: True
Node: <assigned-node>
IP: <pod-ip>
```

Events should normally include:

```text
Scheduled → Pulling → Pulled → Created → Started
```

Inspect the complete object:

```bash
kubectl get pod my-nginx -n myk8s -o yaml
```

Use the output to identify:

```text
metadata = identity
spec     = desired state
status   = observed state
```

## Step 3 — Verify nginx inside the container

```bash
kubectl exec -n myk8s my-nginx -- nginx -v
```

Expected: an nginx version is returned.

## Step 4 — Create the broken-image Pod

```bash
kubectl apply -f 01-pod-fundamentals/manifests/pod-bad-nginx.yaml
kubectl get pod my-bad-nginx -n myk8s -w
```

Stop the watch after the failure is visible.

### Expected result

The Pod should normally progress to:

```text
ErrImagePull → ImagePullBackOff
```

## Step 5 — Troubleshoot the failure

```bash
kubectl describe pod my-bad-nginx -n myk8s
```

### Expected result

Events should show that scheduling succeeded but the image could not be pulled. The useful diagnosis is:

```text
Scheduling problem? No
Image pull problem? Yes
```

You can also inspect namespace events:

```bash
kubectl get events -n myk8s --sort-by=.lastTimestamp
```

## Step 6 — Prove standalone Pod deletion is permanent

```bash
kubectl delete pod my-nginx -n myk8s
kubectl get pod my-nginx -n myk8s
```

### Expected result

The second command should return `NotFound`. Wait a few seconds and confirm no replacement named `my-nginx` appears.

This proves there is no higher-level controller maintaining this standalone Pod.

## Cleanup

```bash
kubectl delete pod my-bad-nginx -n myk8s --ignore-not-found
```

## End-state checklist

You should understand:

```text
API Server → receives the object request
Scheduler  → chooses WHERE
kubelet    → ensures the Pod runs on the Node
containerd → manages the container
```

Troubleshooting flow:

```text
kubectl get pod
      ↓
kubectl describe pod
      ↓
Conditions + Events
```

Continue with [Lesson 02 Hands-on Lab](../02-deployment-replicaset/LAB.md).
