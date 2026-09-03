# Lesson 05 Hands-on Lab — Volume, PV, PVC, StorageClass, and Storage Troubleshooting

Run commands from the repository root.

## Goal

Prove the difference between Pod-lifetime storage and persistent storage, observe dynamic provisioning, test data survival across Pod recreation, observe PVC deletion with `ReclaimPolicy=Delete`, troubleshoot a broken StorageClass, and prove that `emptyDir` survives a container restart inside the same Pod.

---

## Prerequisite and starting state

Verify the namespace and Nodes:

```bash
kubectl get namespace myk8s
kubectl get nodes
```

### Expected result

`myk8s` is `Active` and all lab Nodes are `Ready`.

Inspect storage capability:

```bash
kubectl get storageclass
kubectl get pv
kubectl get pvc -A
```

The reference kind cluster uses:

```text
standard (default)
rancher.io/local-path
ReclaimPolicy: Delete
VolumeBindingMode: WaitForFirstConsumer
```

Other clusters may use a different StorageClass/provisioner. If `standard` does not exist, adapt the PVC manifests to a valid StorageClass before continuing.

---

# Part A — `emptyDir`: Pod-lifetime storage

## Step 1 — Create the `emptyDir` Pod

```bash
kubectl delete pod emptydir-demo -n myk8s --ignore-not-found
kubectl apply -f 05-storage/manifests/emptydir-pod.yaml

kubectl wait \
  --for=condition=Ready \
  pod/emptydir-demo \
  -n myk8s \
  --timeout=120s
```

Check:

```bash
kubectl get pod emptydir-demo -n myk8s -o wide
```

### Expected result

```text
READY   STATUS
1/1     Running
```

## Step 2 — Write data into `emptyDir`

```bash
kubectl exec -n myk8s emptydir-demo -- \
  sh -c 'echo "Kubernetes storage lesson" > /data/message.txt'

kubectl exec -n myk8s emptydir-demo -- \
  cat /data/message.txt
```

### Expected result

```text
Kubernetes storage lesson
```

Inspect the volume:

```bash
kubectl describe pod emptydir-demo -n myk8s
```

Confirm that the output includes a mount similar to:

```text
/data from demo-storage (rw)
```

and:

```text
Type: EmptyDir (a temporary directory that shares a pod's lifetime)
```

## Step 3 — Delete and recreate the Pod

Delete:

```bash
kubectl delete pod emptydir-demo -n myk8s
```

Confirm it is gone:

```bash
kubectl get pod emptydir-demo -n myk8s
```

### Expected result

```text
Error from server (NotFound)
```

Recreate:

```bash
kubectl apply -f 05-storage/manifests/emptydir-pod.yaml

kubectl wait \
  --for=condition=Ready \
  pod/emptydir-demo \
  -n myk8s \
  --timeout=120s
```

Try to read the old file:

```bash
kubectl exec -n myk8s emptydir-demo -- \
  cat /data/message.txt
```

### Expected result

```text
No such file or directory
```

### What this proves

```text
Pod deleted
   ↓
emptyDir deleted
   ↓
new Pod gets new emptyDir
```

Cleanup:

```bash
kubectl delete pod emptydir-demo -n myk8s --ignore-not-found
```

---

# Part B — Dynamic PVC/PV provisioning

## Step 4 — Create a PVC

Ensure an old demo is not present:

```bash
kubectl delete pod pvc-demo -n myk8s --ignore-not-found
kubectl delete pvc demo-pvc -n myk8s --ignore-not-found
```

Apply:

```bash
kubectl apply -f 05-storage/manifests/pvc-demo.yaml
kubectl get pvc demo-pvc -n myk8s
kubectl get pv
```

### Expected result on the reference cluster

Because `standard` uses `WaitForFirstConsumer`:

```text
demo-pvc   Pending
```

and there may still be no PV.

Inspect:

```bash
kubectl describe pvc demo-pvc -n myk8s
```

Expected Event:

```text
WaitForFirstConsumer
waiting for first consumer to be created before binding
```

Important: this `Pending` state is expected, not a failure.

## Step 5 — Create a Pod that consumes the PVC

```bash
kubectl apply -f 05-storage/manifests/pvc-pod.yaml

kubectl wait \
  --for=condition=Ready \
  pod/pvc-demo \
  -n myk8s \
  --timeout=120s
```

Check:

```bash
kubectl get pod pvc-demo -n myk8s -o wide
kubectl get pvc demo-pvc -n myk8s
kubectl get pv
```

### Expected result

```text
Pod = Running
PVC = Bound
A dynamically provisioned PV exists
```

The PV name is generated dynamically and will differ between runs.

## Step 6 — Inspect the PVC/PV binding

Capture the PV dynamically:

```bash
PV=$(kubectl get pvc demo-pvc -n myk8s \
  -o jsonpath='{.spec.volumeName}')

echo "$PV"
```

Inspect both sides:

```bash
kubectl describe pvc demo-pvc -n myk8s
kubectl describe pv "$PV"
```

Confirm:

```text
PVC Status: Bound
PVC Volume: <generated-pv-name>
PV Claim: myk8s/demo-pvc
PV StorageClass: standard
PV Capacity: 100Mi
PV Access Modes: RWO
```

On the reference kind cluster, the PV also showed local-path/HostPath backing and Node affinity to the selected worker. Other storage implementations will differ.

---

# Part C — Prove persistent data survives Pod replacement

## Step 7 — Write data to the persistent volume

```bash
kubectl exec -n myk8s pvc-demo -- \
  sh -c 'echo "Persistent Kubernetes data" > /data/message.txt'

kubectl exec -n myk8s pvc-demo -- \
  cat /data/message.txt
```

### Expected result

```text
Persistent Kubernetes data
```

## Step 8 — Delete only the Pod

```bash
kubectl delete pod pvc-demo -n myk8s
kubectl get pvc demo-pvc -n myk8s
kubectl get pv
```

### Expected result

The Pod is gone, but:

```text
PVC = Bound
PV  = Bound
```

## Step 9 — Recreate the Pod using the same PVC

```bash
kubectl apply -f 05-storage/manifests/pvc-pod.yaml

kubectl wait \
  --for=condition=Ready \
  pod/pvc-demo \
  -n myk8s \
  --timeout=120s
```

Read the old file:

```bash
kubectl exec -n myk8s pvc-demo -- \
  cat /data/message.txt
```

### Expected result

```text
Persistent Kubernetes data
```

### What this proves

```text
Pod #1 deleted
   ↓
PVC/PV remain
   ↓
Pod #2 uses same PVC
   ↓
old data is still available
```

---

# Part D — PVC deletion and ReclaimPolicy

## Step 10 — Record the current PV

```bash
OLD_PV=$(kubectl get pvc demo-pvc -n myk8s \
  -o jsonpath='{.spec.volumeName}')

echo "$OLD_PV"
```

Verify the file one more time:

```bash
kubectl exec -n myk8s pvc-demo -- \
  cat /data/message.txt
```

Expected:

```text
Persistent Kubernetes data
```

## Step 11 — Delete the Pod, keep the PVC

```bash
kubectl delete pod pvc-demo -n myk8s
kubectl get pvc demo-pvc -n myk8s
kubectl get pv "$OLD_PV"
```

### Expected result

```text
PVC = Bound
PV  = Bound
```

## Step 12 — Delete the PVC

```bash
kubectl delete pvc demo-pvc -n myk8s
```

Optionally watch the PV lifecycle in another terminal:

```bash
kubectl get pv -w
```

The reference lab observed approximately:

```text
Bound
 ↓
Released
 ↓
Terminating
 ↓
removed
```

Stop the watch with `Ctrl+C`.

Check final state:

```bash
kubectl get pvc -n myk8s
kubectl get pv
```

### Expected result

`demo-pvc` and its old dynamically provisioned PV no longer exist.

Why:

```text
PVC deleted
   ↓
ReclaimPolicy = Delete
   ↓
PV/backing storage removed
```

## Step 13 — Recreate the same PVC and Pod

```bash
kubectl apply -f 05-storage/manifests/pvc-demo.yaml
kubectl get pvc demo-pvc -n myk8s
```

Expected before a consumer exists:

```text
Pending
```

Create the consumer:

```bash
kubectl apply -f 05-storage/manifests/pvc-pod.yaml

kubectl wait \
  --for=condition=Ready \
  pod/pvc-demo \
  -n myk8s \
  --timeout=120s
```

Check:

```bash
kubectl get pvc demo-pvc -n myk8s
kubectl get pv
```

Capture the new PV:

```bash
NEW_PV=$(kubectl get pvc demo-pvc -n myk8s \
  -o jsonpath='{.spec.volumeName}')

printf 'Old PV: %s\nNew PV: %s\n' "$OLD_PV" "$NEW_PV"
```

### Expected result

The PV names should differ.

Try the old file:

```bash
kubectl exec -n myk8s pvc-demo -- \
  cat /data/message.txt
```

### Expected result

```text
No such file or directory
```

### What this proves

```text
Delete Pod only
→ data survives

Delete PVC with ReclaimPolicy=Delete
→ old PV/storage removed
→ recreated PVC gets new empty storage
```

---

# Part E — Storage troubleshooting

## Step 14 — Create a PVC with a nonexistent StorageClass

Ensure old broken resources are absent:

```bash
kubectl delete pod broken-storage -n myk8s --ignore-not-found
kubectl delete pvc broken-pvc -n myk8s --ignore-not-found
```

Create the broken claim:

```bash
kubectl apply -f 05-storage/manifests/broken-pvc.yaml
kubectl get pvc broken-pvc -n myk8s
```

### Expected result

```text
STATUS = Pending
STORAGECLASS = does-not-exist
```

Inspect:

```bash
kubectl describe pvc broken-pvc -n myk8s
```

### Expected failure

```text
ProvisioningFailed
storageclass.storage.k8s.io "does-not-exist" not found
```

## Step 15 — Create a Pod that requires the broken PVC

```bash
kubectl apply -f 05-storage/manifests/broken-storage-pod.yaml
sleep 5

kubectl get pod broken-storage -n myk8s
kubectl get pvc broken-pvc -n myk8s
```

### Expected result

```text
Pod = Pending
PVC = Pending
```

Inspect the Pod:

```bash
kubectl describe pod broken-storage -n myk8s
```

Expected indicators:

```text
Node: <none>
PodScheduled: False
FailedScheduling
pod has unbound immediate PersistentVolumeClaims
```

Troubleshooting chain:

```text
Pod Pending
   ↓
kubectl describe pod
   ↓
unbound PVC
   ↓
kubectl describe pvc
   ↓
ProvisioningFailed
   ↓
StorageClass not found
```

## Step 16 — Repair the failure

Delete the broken Pod and claim:

```bash
kubectl delete pod broken-storage -n myk8s --ignore-not-found
kubectl delete pvc broken-pvc -n myk8s --ignore-not-found
```

Create the same claim name with the valid StorageClass:

```bash
kubectl apply -f 05-storage/manifests/fixed-pvc.yaml
kubectl get pvc broken-pvc -n myk8s
```

On the reference cluster it may initially be `Pending` because of `WaitForFirstConsumer`. This is expected.

Create the consumer again:

```bash
kubectl apply -f 05-storage/manifests/broken-storage-pod.yaml

kubectl wait \
  --for=condition=Ready \
  pod/broken-storage \
  -n myk8s \
  --timeout=120s
```

Check:

```bash
kubectl get pod broken-storage -n myk8s -o wide
kubectl get pvc broken-pvc -n myk8s
kubectl describe pvc broken-pvc -n myk8s
```

### Expected result

```text
Pod = Running
PVC = Bound
```

The PVC Events should show successful provisioning rather than `ProvisioningFailed`.

Important lesson:

```text
Pending + WaitForFirstConsumer
→ expected waiting state

Pending + ProvisioningFailed
→ actual storage failure
```

---

# Part F — Prove `emptyDir` survives a container restart

## Why this experiment exists

A Pod and its container do not have the same lifecycle. Kubernetes can restart a container while preserving the same Pod object.

To prove that experimentally, compare:

```text
Pod UID        → same
Container ID   → changes
Restart Count  → increases
Started At     → changes
```

Then verify the `emptyDir` file is still present.

## Step 17 — Create a restartable Pod

The manifest intentionally installs a SIGTERM trap in PID 1 so the termination is deterministic and reproducible.

```bash
kubectl delete pod emptydir-restart -n myk8s --ignore-not-found
kubectl apply -f 05-storage/manifests/emptydir-restart.yaml

kubectl wait \
  --for=condition=Ready \
  pod/emptydir-restart \
  -n myk8s \
  --timeout=120s
```

## Step 18 — Write proof data

```bash
kubectl exec -n myk8s emptydir-restart -- \
  sh -c 'echo "I survived a container restart" > /data/restart-proof.txt'

kubectl exec -n myk8s emptydir-restart -- \
  cat /data/restart-proof.txt
```

Expected:

```text
I survived a container restart
```

## Step 19 — Capture Pod/container identity before restart

```bash
kubectl get pod emptydir-restart -n myk8s \
  -o jsonpath='Pod UID: {.metadata.uid}{"\n"}Container ID: {.status.containerStatuses[0].containerID}{"\n"}Restart Count: {.status.containerStatuses[0].restartCount}{"\n"}Started At: {.status.containerStatuses[0].state.running.startedAt}{"\n"}'
```

Record the values.

Expected initial restart count:

```text
Restart Count: 0
```

## Step 20 — Terminate PID 1

```bash
kubectl exec -n myk8s emptydir-restart -- kill -TERM 1
sleep 5
```

The container command is designed to receive `SIGTERM` and exit with code `1`. Because `restartPolicy: Always`, kubelet should start another container instance inside the same Pod.

## Step 21 — Prove the restart

Run the same identity query:

```bash
kubectl get pod emptydir-restart -n myk8s \
  -o jsonpath='Pod UID: {.metadata.uid}{"\n"}Container ID: {.status.containerStatuses[0].containerID}{"\n"}Restart Count: {.status.containerStatuses[0].restartCount}{"\n"}Started At: {.status.containerStatuses[0].state.running.startedAt}{"\n"}'
```

### Expected comparison

```text
Pod UID        SAME
Container ID   DIFFERENT
Restart Count  0 → 1
Started At     NEW timestamp
```

Inspect:

```bash
kubectl describe pod emptydir-restart -n myk8s
```

Expected container state information similar to:

```text
State: Running
Last State: Terminated
Reason: Error
Exit Code: 1
Restart Count: 1
```

## Step 22 — Prove `emptyDir` survived

```bash
kubectl exec -n myk8s emptydir-restart -- \
  cat /data/restart-proof.txt
```

### Expected result

```text
I survived a container restart
```

### What this proves

```text
same Pod UID
+ different Container ID
+ Restart Count increased
+ same emptyDir data

→ container restarted inside the same Pod
→ emptyDir lifetime belongs to the Pod, not the container instance
```

---

# Final cleanup

Remove Lesson 05 test resources:

```bash
kubectl delete pod pvc-demo broken-storage emptydir-restart emptydir-demo \
  -n myk8s --ignore-not-found

kubectl delete pvc demo-pvc broken-pvc \
  -n myk8s --ignore-not-found
```

Because the reference StorageClass/PVs use `ReclaimPolicy=Delete`, dynamically provisioned PVs should subsequently disappear.

Verify:

```bash
kubectl get pod -n myk8s
kubectl get pvc -n myk8s
kubectl get pv
```

### Expected Lesson 05 end state

Lesson-specific Pods and PVCs are removed. Dynamically provisioned Lesson 05 PVs are removed after reclamation.

The existing `web` Deployment/Service from earlier lessons may remain and can be reused for Lesson 06.

---

# Final mental model

```text
Container writable filesystem
        ↓
container instance lifetime

emptyDir
        ↓
Pod lifetime

Pod
 ↓
PVC               WHAT storage is requested
 ↓
StorageClass      HOW dynamic storage is provided
 ↓
Provisioner
 ↓
PV                allocated persistent storage resource
 ↓
Storage backend   actual data location
```

Lifecycle summary:

```text
Container restart
→ same Pod
→ emptyDir survives

Pod replacement
→ emptyDir lost

Pod replacement while PVC remains
→ PV remains
→ data survives

PVC deletion with ReclaimPolicy=Delete
→ PV/storage removed
→ data lost
```

Continue with Lesson 06 when it is added to the repository.
