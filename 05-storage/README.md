# Lesson 05 — Storage: Volume, PersistentVolume, PersistentVolumeClaim, and StorageClass

## Objective

Understand Kubernetes storage lifecycles and the relationship between:

```text
Container filesystem
emptyDir
PersistentVolumeClaim (PVC)
PersistentVolume (PV)
StorageClass
Storage backend
```

The core question is:

> What happens when application data must survive container or Pod lifecycle changes?

---

## 1. Storage Lifetime Is the Key Concept

The easiest way to distinguish Kubernetes storage types is to ask:

> Who owns the storage lifetime?

```text
Container writable filesystem
→ normally tied to the container instance

emptyDir
→ tied to the Pod

PVC/PV
→ storage lifecycle is independent of the Pod
```

Persistent does **not** mean permanent. It means the storage lifecycle is not tied to the Pod lifecycle.

---

## 2. Container Filesystem vs emptyDir

A container has its own writable filesystem layer:

```text
Pod
└── Container
      ├── image filesystem
      └── writable container layer
```

If that container instance is replaced, data written only to the container's writable layer is normally lost.

An `emptyDir` is different. Kubernetes creates the volume for the Pod and mounts it into one or more containers:

```text
Pod
├── emptyDir
│    └── data
│
└── Container
     └── /data
          ↑
          └── mounted emptyDir
```

Important behavior:

```text
Container restarts inside same Pod
→ same emptyDir survives

Pod deleted/replaced
→ emptyDir is deleted
→ new Pod receives a new emptyDir
```

Typical `emptyDir` uses:

- scratch space
- temporary cache
- intermediate processing files
- sharing files between containers in the same Pod

It is not suitable for data that must survive Pod replacement.

---

## 3. Proving a Container Restart Is Not a Pod Replacement

A Pod and its containers have separate identities.

To prove a container restarted inside the same Pod, compare:

```text
Pod UID        → stays the same
Container ID   → changes
Restart Count  → increases
Started At     → changes
```

Reference lab observation:

```text
Before
Pod UID: same-Pod-UID
Container ID: container-A
Restart Count: 0

After terminating PID 1
Pod UID: same-Pod-UID
Container ID: container-B
Restart Count: 1
```

`kubectl describe pod` also showed:

```text
State: Running
Last State: Terminated
Exit Code: 1
Restart Count: 1
```

The file stored in `emptyDir` remained available after the container restart.

This proves:

```text
same Pod
+ new container instance
+ same emptyDir
```

---

## 4. Persistent Storage Relationship

The normal persistent storage model is:

```text
Pod
 ↓ uses
PVC
 ↓ binds to
PV
 ↓ represents
Actual storage backend
```

Simple responsibilities:

```text
Pod = workload that needs storage
PVC = storage request / claim / binding point
PV  = storage resource Kubernetes gives to the claim
```

A useful beginner mental model is:

> The PVC is the Pod's storage request and connection point to persistent storage.

The Pod references a PVC; the PVC is an independent Kubernetes object and can exist before or after the Pod.

---

## 5. PVC Is Not a Module Inside the Pod

A PVC is not contained inside the Pod.

The Pod only references it:

```text
Pod
└── volume
     └── persistentVolumeClaim
          └── demo-pvc
```

This is important because:

```text
PVC can exist before Pod
PVC can remain after Pod deletion
```

So the better language is:

```text
Pod consumes storage through a PVC.
PVC binds to a PV.
PV represents the storage resource.
```

---

## 6. ConfigMap vs PersistentVolume

ConfigMap and PV-backed storage can both appear as files inside a Pod, but they solve different problems and are not interchangeable.

```text
ConfigMap = application configuration
PV/PVC    = persistent application data
```

### ConfigMap

A ConfigMap is a Kubernetes API object used for non-sensitive configuration.

Typical examples:

```text
nginx.conf
feature flags
API endpoint
log level
small text configuration
```

The administrator or deployment process supplies the data; the application normally reads it.

### PV/PVC

Persistent storage is where the application can create and modify runtime data.

Typical examples:

```text
database files
uploads
application-generated files
persistent logs
transaction data
```

A useful rule:

```text
"How should the application run?"
→ ConfigMap

"What data did the application create and need to keep?"
→ Persistent storage
```

---

## 7. What Is a StorageClass?

A StorageClass is a storage policy/template that tells Kubernetes how dynamically provisioned storage should be created.

```text
PVC
 ↓
StorageClass
 ↓
Provisioner
 ↓
PV
 ↓
Actual storage
```

Simple memory aid:

```text
PVC          = WHAT storage I need
StorageClass = HOW storage should be provided
PV           = the storage Kubernetes gives me
```

StorageClass is not mandatory for every possible PV/PVC design. Static provisioning can use pre-created PVs. StorageClass is the normal mechanism for dynamic provisioning.

`storageClassName` is also not always mandatory on a PVC. If it is omitted and a default StorageClass exists, Kubernetes can use that default class.

Important distinction:

```text
storageClassName: standard
→ explicitly request standard

storageClassName omitted
→ default StorageClass may be used

storageClassName: ""
→ do not request a StorageClass
```

---

## 8. Reference Cluster StorageClass

The reference kind cluster reported:

```text
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

Meaning:

```text
Provisioner
→ rancher.io/local-path

ReclaimPolicy
→ Delete

VolumeBindingMode
→ WaitForFirstConsumer
```

With `WaitForFirstConsumer`, a new PVC can remain `Pending` until a Pod actually requests it.

Observed flow:

```text
Create PVC
   ↓
PVC Pending
   ↓
Event: WaitForFirstConsumer
   ↓
Create Pod using PVC
   ↓
Provisioner creates PV
   ↓
PVC Bound
   ↓
Pod starts
```

---

## 9. Dynamic Provisioning

Dynamic provisioning removes the need for an administrator to manually create every PV in advance.

```text
Developer creates PVC
        ↓
StorageClass
        ↓
Provisioner
        ↓
PV created automatically
```

The reference lab created a `100Mi`, `ReadWriteOnce` claim and the local-path provisioner automatically created a matching PV.

---

## 10. ReadWriteOnce Does Not Mean One Pod

The lab PV used:

```text
Access Modes: RWO
```

`RWO` means ReadWriteOnce: the volume can be mounted read-write by a single Node at a time.

It does **not** strictly mean only one Pod. Depending on the storage implementation, multiple Pods on the same Node may potentially use an RWO volume.

---

## 11. Local-Path Storage in the Reference Lab

The dynamically created PV showed:

```text
Node Affinity:
  kubernetes.io/hostname in [kind-worker2]

Source:
  Type: HostPath
  Path: /var/local-path-provisioner/...
```

So the reference lab's persistent data was independent of the Pod, but still backed by storage local to one kind worker Node.

```text
Pod
 ↓
PVC
 ↓
PV
 ↓
kind worker local path
```

This is useful for learning but should not be confused with highly available distributed/cloud storage such as EBS, Azure Disk, NFS, Ceph, or SAN storage.

---

## 12. Pod Deletion vs PVC Deletion

This was the most important persistent-storage experiment.

### Delete only the Pod

```text
Pod deleted
   ↓
PVC still Bound
   ↓
PV still Bound
   ↓
data survives
```

A recreated Pod using the same PVC successfully read the old file.

### Delete the PVC

The StorageClass/PV used:

```text
ReclaimPolicy: Delete
```

Observed lifecycle:

```text
PV Bound
   ↓
PVC deleted
   ↓
PV Released
   ↓
PV Terminating
   ↓
PV removed
   ↓
backing storage removed
```

When the same PVC definition was created again, Kubernetes provisioned a different PV and the old file no longer existed.

Therefore:

```text
Delete Pod
→ persistent data survives

Delete PVC with Delete reclaim policy
→ PV/storage is deleted
→ data is lost
```

---

## 13. Storage Troubleshooting

A PVC was intentionally configured with:

```yaml
storageClassName: does-not-exist
```

The PVC remained:

```text
Pending
```

and `kubectl describe pvc` showed:

```text
ProvisioningFailed
storageclass.storage.k8s.io "does-not-exist" not found
```

A Pod referencing that PVC also remained:

```text
Pending
PodScheduled: False
Node: <none>
```

with an Event similar to:

```text
FailedScheduling
pod has unbound immediate PersistentVolumeClaims
```

Troubleshooting path:

```text
Pod Pending
   ↓
kubectl describe pod
   ↓
Pod needs PVC
   ↓
PVC Pending
   ↓
kubectl describe pvc
   ↓
ProvisioningFailed
   ↓
check StorageClass / provisioner
```

Important lesson:

```text
PVC Pending + WaitForFirstConsumer
→ can be healthy/expected

PVC Pending + ProvisioningFailed
→ storage problem
```

Always read Events; `Pending` by itself is not enough diagnosis.

---

## 14. Final Storage Mental Model

```text
Container writable filesystem
        ↓
container instance lifetime

emptyDir
        ↓
Pod lifetime

PVC
        ↓
storage request / binding point independent of Pod

StorageClass
        ↓
how dynamic storage should be provisioned

PV
        ↓
persistent storage resource

Storage backend
        ↓
actual data location
```

And the lifecycle summary:

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

---

## Hands-on Lab

Follow the complete reproducible procedure in [LAB.md](LAB.md).

---

# Next Lesson

## Lesson 06 — Ingress and External Access

Next question:

> Services provide stable access inside the cluster, but how should applications be exposed to clients outside the cluster?
