# Lesson 00 Hands-on Lab — Reproducible kind, Cilium, and Storage Setup

Run commands from the repository root unless stated otherwise.

## Goal

Build the complete reference environment used by the later lessons:

```text
kind
├── 1 control-plane
├── 2 workers
├── no default CNI
├── no kube-proxy
│
├── Cilium 1.20.1
│   ├── CNI
│   ├── kube-proxy replacement
│   ├── Envoy
│   └── Ingress controller
│
├── Local Path Provisioner 0.0.37
│   └── default StorageClass: standard
│
└── namespace: myk8s
```

Pinned lab versions in this runbook:

```text
Cilium:                     1.20.1
Rancher Local Path chart:   0.0.37
```

Kubernetes/kind versions may be newer as long as they are compatible with the pinned components.

---

# Part A — Verify required tools

## Step 1 — Check the tools

```bash
docker version
kind version
kubectl version --client
helm version
```

### Expected result

All commands return version information without errors.

---

# Part B — Create the reference kind cluster

## Step 2 — Review the kind configuration

```bash
cat 00-prerequisites/kind-config.yaml
```

The important networking section is:

```yaml
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.11.0.0/16"
```

Meaning:

```text
disableDefaultCNI: true
→ kind does not install its default Pod networking

kubeProxyMode: "none"
→ kind does not install kube-proxy
```

This is intentional because Cilium will provide both Pod networking and kube-proxy replacement.

## Step 3 — Check whether a cluster already exists

```bash
kind get clusters
```

If a cluster named `kind` already exists and you want a completely clean rebuild, first make sure any important Kubernetes data is disposable, then delete it:

```bash
kind delete cluster --name kind
```

> Deleting the kind cluster deletes Kubernetes objects and local lab PV data. The Git repository is independent and is not deleted.

## Step 4 — Create the cluster

```bash
kind create cluster \
  --name kind \
  --config 00-prerequisites/kind-config.yaml
```

Verify:

```bash
kind get clusters
kubectl get nodes -o wide
```

### Expected result at this stage

The three Nodes exist but are normally `NotReady`:

```text
kind-control-plane   NotReady
kind-worker          NotReady
kind-worker2         NotReady
```

This is expected because no CNI has been installed yet.

Inspect system Pods:

```bash
kubectl get pods -n kube-system -o wide
```

CoreDNS is expected to be `Pending` until Pod networking is available.

Confirm kube-proxy is absent:

```bash
kubectl get ds kube-proxy -n kube-system
```

Expected:

```text
Error from server (NotFound)
```

A useful Node check is:

```bash
kubectl describe node kind-worker | grep -A5 -B2 'Ready'
```

Expected reason is similar to:

```text
NetworkPluginNotReady
cni plugin not initialized
```

### What this proves

```text
Kubernetes control plane works
        +
CNI intentionally absent
        ↓
Nodes NotReady is expected
```

---

# Part C — Install Cilium

## Step 5 — Add the Cilium Helm repository

```bash
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update
```

Review the reusable values:

```bash
cat 00-prerequisites/cilium-values.yaml
```

## Step 6 — Discover the direct Kubernetes API endpoint

Because kube-proxy is absent, Cilium must be given a direct API server address during bootstrap.

Discover the kind control-plane container IP dynamically:

```bash
API_SERVER_IP=$(docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  kind-control-plane)

API_SERVER_PORT=6443

echo "${API_SERVER_IP}:${API_SERVER_PORT}"
```

Do not hard-code the IP. It may change after the cluster is recreated.

Conceptually:

```text
Cilium Agent
     │
     │ direct bootstrap connection
     ▼
kind-control-plane:6443
     ▼
Kubernetes API Server
```

## Step 7 — Install Cilium

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.20.1 \
  --namespace kube-system \
  -f 00-prerequisites/cilium-values.yaml \
  --set k8sServiceHost="${API_SERVER_IP}" \
  --set k8sServicePort="${API_SERVER_PORT}"
```

Normal runtime image pulling is sufficient. Preloading the image into kind is optional and is not required by this lab.

Watch the installation:

```bash
kubectl get pods -n kube-system -w
```

Stop with `Ctrl+C` when Cilium, Cilium Envoy, Cilium Operator, and CoreDNS are Running.

## Step 8 — Verify Node and Cilium health

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
kubectl get ds -n kube-system
```

### Expected result

All three Nodes become `Ready`.

Cilium and Cilium Envoy should have one ready Pod per Node.

Confirm kube-proxy is still absent:

```bash
kubectl get ds kube-proxy -n kube-system
```

Expected:

```text
Error from server (NotFound)
```

Check Cilium:

```bash
kubectl exec -n kube-system ds/cilium \
  -c cilium-agent -- \
  cilium-dbg status
```

Important lines should show conceptually:

```text
Kubernetes:             Ok
Cilium:                 Ok
KubeProxyReplacement:   True
Proxy Status:           OK
Cluster health:         3/3 reachable
```

Verify the IngressClass:

```bash
kubectl get ingressclass
```

Expected:

```text
NAME     CONTROLLER
cilium   cilium.io/ingress-controller
```

Verify the key configuration:

```bash
kubectl -n kube-system get cm cilium-config -o yaml | \
  grep -E 'kube-proxy-replacement|enable-envoy-config|enable-ingress-controller|enable-l7-proxy'
```

Expected values are `true`.

### What this proves

```text
Cilium
├── initialized the CNI
├── made Nodes Ready
├── replaced kube-proxy
├── started Envoy
└── registered the Cilium IngressClass
```

---

# Part D — Install dynamic local storage

## Why this is required

Lesson 05 uses dynamic PVC/PV provisioning and expects this StorageClass:

```text
Name:               standard
Provisioner:        rancher.io/local-path
Default:            yes
ReclaimPolicy:      Delete
VolumeBindingMode:  WaitForFirstConsumer
```

The local-path provisioner is only for this learning environment. The backing data is local to a kind Node.

## Step 9 — Review the storage values

```bash
cat 00-prerequisites/local-path-values.yaml
```

## Step 10 — Install Rancher Local Path Provisioner

```bash
helm upgrade --install local-path-provisioner \
  oci://ghcr.io/rancher/local-path-provisioner/charts/local-path-provisioner \
  --version 0.0.37 \
  --namespace local-path-storage \
  --create-namespace \
  -f 00-prerequisites/local-path-values.yaml
```

Verify the provisioner:

```bash
kubectl get pods -n local-path-storage
```

Wait until the provisioner Pod is `Running` and Ready.

Verify storage classes:

```bash
kubectl get storageclass
```

### Expected result

The reference class should look conceptually like:

```text
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

Also verify there are no old claims or volumes in a fresh cluster:

```bash
kubectl get pvc -A
kubectl get pv
```

### What this proves

```text
PVC
 ↓
standard StorageClass
 ↓
rancher.io/local-path
 ↓
dynamically created PV
 ↓
local Node storage
```

---

# Part E — Create the learning namespace

## Step 11 — Create `myk8s`

```bash
kubectl apply -f 00-prerequisites/manifests/namespace-myk8s.yaml
```

Verify:

```bash
kubectl get namespace myk8s
```

Expected:

```text
NAME     STATUS
myk8s    Active
```

## Step 12 — Final readiness check

```bash
kubectl auth can-i create pods -n myk8s
kubectl get nodes
kubectl get storageclass
kubectl get ingressclass
```

Expected:

```text
Pod creation permission: yes
Nodes:                   Ready
StorageClass:            standard (default)
IngressClass:            cilium
kube-proxy:              absent
```

## End state

```text
Kubernetes control plane
        +
3 Ready kind Nodes
        +
Cilium CNI
        +
Cilium kube-proxy replacement
        +
Cilium Envoy / Ingress
        +
standard dynamic StorageClass
        +
myk8s namespace
        ↓
Ready for Lesson 01
```

Continue with [Lesson 01 Hands-on Lab](../01-pod-fundamentals/LAB.md).

---

# Troubleshooting Quick Reference

If Nodes remain `NotReady` after Cilium installation:

```bash
kubectl get pods -n kube-system -o wide
kubectl logs -n kube-system ds/cilium -c cilium-agent --tail=100
kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg status
```

If Cilium cannot reach Kubernetes, re-check the dynamically discovered API endpoint:

```bash
echo "${API_SERVER_IP}:${API_SERVER_PORT}"
docker inspect kind-control-plane
```

If storage provisioning is unavailable:

```bash
kubectl get pods -n local-path-storage
kubectl get storageclass
kubectl logs -n local-path-storage -l app.kubernetes.io/name=local-path-provisioner --tail=100
```

If a later PVC remains Pending, inspect the claim Events before assuming failure:

```bash
kubectl describe pvc <pvc-name> -n myk8s
```

`WaitForFirstConsumer` can intentionally leave a PVC Pending until a Pod uses it.
