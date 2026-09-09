# Lesson 00 Hands-on Lab — Fresh Ubuntu to Reproducible kind, Cilium, and Storage Setup

This runbook is designed to work from a fresh Ubuntu installation.

If your required tools are already installed, verify them in Part B and continue from the first missing step.

## Goal

Build the complete reference environment used by the later lessons:

```text
Fresh Ubuntu
    ↓
Required tools
    ├── Git
    ├── Docker Engine
    ├── kubectl
    ├── kind
    └── Helm
    ↓
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

Pinned/tested lab versions in this runbook:

```text
kubectl:                     1.36.1
kind:                        0.33.0
Helm:                        4.2.4
Cilium:                      1.20.1
Rancher Local Path chart:    0.0.37
```

Docker Engine is installed from Docker's official Ubuntu APT repository rather than pinning a specific package build.

> If you intentionally change Kubernetes, kind, Cilium, or Helm versions, verify version compatibility before assuming the exact observations in later lessons will be identical.

---

# Part A — Prepare a fresh Ubuntu host

## Step 1 — Identify Ubuntu and CPU architecture

```bash
cat /etc/os-release
uname -m
dpkg --print-architecture
```

Common architecture mapping:

```text
x86_64 / amd64   → amd64
aarch64 / arm64  → arm64
```

This runbook supports the common `amd64` and `arm64` Linux binaries used by the lab tools.

Set a reusable architecture variable:

```bash
ARCH=$(dpkg --print-architecture)

case "$ARCH" in
  amd64|arm64)
    echo "Using architecture: $ARCH"
    ;;
  *)
    echo "Unsupported architecture for this runbook: $ARCH"
    exit 1
    ;;
esac
```

## Step 2 — Update Ubuntu and install base packages

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  git \
  jq \
  openssl \
  tar
```

Verify:

```bash
git --version
curl --version | head -n 1
jq --version
```

---

# Part B — Install and verify the required tools

## Step 3 — Install Docker Engine from Docker's official Ubuntu repository

Create the APT keyring directory and add Docker's signing key:

```bash
sudo install -m 0755 -d /etc/apt/keyrings

sudo curl -fsSL \
  https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

sudo chmod a+r /etc/apt/keyrings/docker.asc
```

Add the Docker repository:

```bash
. /etc/os-release

printf '%s\n' \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

Install Docker Engine and related plugins:

```bash
sudo apt-get update
sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

Enable Docker:

```bash
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
```

Allow the current user to run Docker without `sudo`:

```bash
sudo usermod -aG docker "$USER"
```

**Important:** group membership is normally applied at the next login. Log out and log back in before continuing. If you intentionally want to refresh the group in the current terminal, you can run:

```bash
newgrp docker
```

After the login/group refresh, verify Docker without `sudo`:

```bash
docker version
docker run --rm hello-world
```

### Expected result

The Docker client can communicate with the Docker daemon and `hello-world` completes successfully.

---

## Step 4 — Install kubectl 1.36.1

The reference kind cluster currently runs Kubernetes 1.36.1, so this runbook pins the matching kubectl version.

```bash
KUBECTL_VERSION=v1.36.1
ARCH=$(dpkg --print-architecture)

curl -L --fail \
  -o /tmp/kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"

curl -L --fail \
  -o /tmp/kubectl.sha256 \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"

echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check

sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubectl /tmp/kubectl.sha256
```

Verify:

```bash
kubectl version --client
```

### Expected result

The client reports Kubernetes `v1.36.1`.

---

## Step 5 — Install kind 0.33.0

The lab pins kind `v0.33.0` so the cluster build remains reproducible.

```bash
KIND_VERSION=v0.33.0
ARCH=$(dpkg --print-architecture)

curl -L --fail \
  -o /tmp/kind \
  "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"

curl -L --fail \
  -o /tmp/kind.sha256sum \
  "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}.sha256sum"

KIND_SHA=$(awk '{print $1}' /tmp/kind.sha256sum)
echo "${KIND_SHA}  /tmp/kind" | sha256sum --check

sudo install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
rm -f /tmp/kind /tmp/kind.sha256sum
```

Verify:

```bash
kind version
```

### Expected result

The output reports kind `v0.33.0`.

---

## Step 6 — Install Helm 4.2.4

Download Helm's official installation script first so it is visible before execution:

```bash
curl -fsSL \
  -o /tmp/get_helm.sh \
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4

chmod 700 /tmp/get_helm.sh
```

Install the pinned Helm release:

```bash
/tmp/get_helm.sh --version v4.2.4
rm -f /tmp/get_helm.sh
```

Verify:

```bash
helm version
```

### Expected result

The Helm client reports version `v4.2.4`.

---

## Step 7 — Verify the complete toolchain

```bash
git --version
docker version
kubectl version --client
kind version
helm version
```

### Expected result

All commands return version information without errors and Docker works without `sudo`.

Mental model:

```text
Ubuntu host
   ↓
Docker Engine
   ↓
kind
   ↓
Kubernetes Nodes

kubectl → Kubernetes API
Helm    → package/install Kubernetes applications
Git     → preserve the declarative lab source
```

---

# Part C — Get the lab repository

## Step 8 — Clone or update the repository

If the repository has not been cloned yet:

```bash
cd ~

git clone \
  https://github.com/Th3Z3r0/kubernetes-learning-lab.git

cd ~/kubernetes-learning-lab
```

If it already exists:

```bash
cd ~/kubernetes-learning-lab
git status -sb
git pull --rebase origin main
```

Before cluster creation, confirm the prerequisite files exist:

```bash
ls -l 00-prerequisites/
```

Expected important files:

```text
LAB.md
README.md
kind-config.yaml
cilium-values.yaml
local-path-values.yaml
manifests/
```

---

# Part D — Create the reference kind cluster

## Step 9 — Review the kind configuration

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

## Step 10 — Check whether a cluster already exists

```bash
kind get clusters
```

If a cluster named `kind` already exists and you want a completely clean rebuild, first make sure any important Kubernetes data is disposable, then delete it:

```bash
kind delete cluster --name kind
```

> Deleting the kind cluster deletes Kubernetes objects and local lab PV data. The Git repository is independent and is not deleted.

## Step 11 — Create the cluster

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

# Part E — Install Cilium

## Step 12 — Add the Cilium Helm repository

```bash
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update
```

Review the reusable values:

```bash
cat 00-prerequisites/cilium-values.yaml
```

## Step 13 — Discover the direct Kubernetes API endpoint

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

## Step 14 — Install Cilium

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

## Step 15 — Verify Node and Cilium health

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

# Part F — Install dynamic local storage

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

## Step 16 — Review the storage values

```bash
cat 00-prerequisites/local-path-values.yaml
```

## Step 17 — Install Rancher Local Path Provisioner

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

# Part G — Create the learning namespace

## Step 18 — Create `myk8s`

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

## Step 19 — Final readiness check

```bash
kubectl auth can-i create pods -n myk8s
kubectl get nodes
kubectl get storageclass
kubectl get ingressclass
kubectl get ds -n kube-system
```

Expected:

```text
Pod creation permission: yes
Nodes:                   Ready
StorageClass:            standard (default)
IngressClass:            cilium
Cilium:                   Ready on all Nodes
Cilium Envoy:             Ready on all Nodes
kube-proxy:               absent
```

## End state

```text
Fresh Ubuntu toolchain
        +
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

## Docker permission denied

If this fails without `sudo`:

```bash
docker ps
```

check group membership:

```bash
id
getent group docker
```

If your user was just added to the `docker` group, log out and log back in, then retry.

## kind cannot create Nodes

Verify Docker first:

```bash
docker version
docker ps
```

Then:

```bash
kind get clusters
```

## Nodes remain `NotReady` after Cilium installation

```bash
kubectl get pods -n kube-system -o wide
kubectl logs -n kube-system ds/cilium -c cilium-agent --tail=100
kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg status
```

## Cilium cannot reach Kubernetes

Re-check the dynamically discovered API endpoint:

```bash
echo "${API_SERVER_IP}:${API_SERVER_PORT}"
docker inspect kind-control-plane
```

## Storage provisioning is unavailable

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
