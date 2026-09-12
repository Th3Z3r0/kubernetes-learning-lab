# Automated Lab Bootstrap

The manual commands in `LAB.md` are useful for learning and troubleshooting. For a fresh Ubuntu host, the recommended preparation method is:

```text
install Git + curl
        ↓
clone this repository
        ↓
bash 00-prerequisites/scripts/bootstrap-lab.sh
```

A separate validator checks each stage independently:

```text
bash 00-prerequisites/scripts/validate-lab.sh
```

## Fresh Ubuntu Quick Start

A brand-new Ubuntu host cannot run a script from this repository until the repository exists locally. Therefore the preferred bootstrap entrypoint has one small manual stage first.

Install Git and curl:

```bash
sudo apt-get update
sudo apt-get install -y git curl
```

Clone the repository:

```bash
cd ~
git clone https://github.com/Th3Z3r0/kubernetes-learning-lab.git
cd ~/kubernetes-learning-lab
```

Verify the clone:

```bash
git status
ls 00-prerequisites/scripts/
```

Run the automated bootstrap explicitly with Bash:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh
```

Do **not** change the executable bit on the tracked repository scripts. They are intentionally invoked with `bash`. A tracked file-mode change from `100644` to `100755` can make the working tree dirty and can block operations such as `git pull --rebase`.

From this point onward, the bootstrap installs/configures the required host and Kubernetes components and validates each stage.

The full first-host workflow is therefore:

```text
Fresh Ubuntu
    ↓
sudo apt-get install git curl
    ↓
git clone
    ↓
bash bootstrap-lab.sh
    ↓
capacity + compatibility preflight
    ↓
Docker + kubectl + kind + Helm
    ↓
kind + Cilium + storage + namespace
    ↓
validation/smoke tests
```

## Design Goal

The automation is future-aware rather than permanently pinned to the versions that happened to be current when the lab was written.

```text
Official stable release
        +
checksum / package validation
        +
capacity preflight
        +
compatibility preflight
        +
runtime validation
        ↓
use or install the component
```

"Best version" does not mean blindly installing the newest artifact. The bootstrap discovers stable upstream releases, checks compatibility, validates the resulting behavior, and stops when a future change no longer matches the lab architecture.

## Host Capacity Preflight

Before building the full lab, the bootstrap checks free root-disk capacity and free inodes.

Default policy:

```text
free disk < 20 GiB
→ fail before kind/Cilium installation

free disk 20–29 GiB
→ warn

free disk >= 30 GiB
→ pass comfortably

free inodes < 100000
→ fail
```

The thresholds can be overridden with:

```text
MIN_FREE_GIB
WARN_FREE_GIB
MIN_FREE_INODES
```

The defaults are lab safety policy, not general Kubernetes platform requirements.

## Version Resolution Strategy

| Component | Default source | Safety behavior |
|---|---|---|
| Docker Engine | Docker official Ubuntu `stable` APT repository | installs/updates the stable package and validates the daemon with `hello-world` |
| kubectl | Kubernetes `stable.txt` | verifies SHA-256 and checks client/server minor-version skew after kind is created |
| kind | latest stable GitHub release | verifies the downloaded binary SHA-256 and inspects the node images published for that release |
| Kubernetes node image | digest-pinned `kindest/node` image from the selected kind release | chooses the highest Kubernetes minor that is listed as e2e-tested by the selected Cilium release |
| Helm | latest stable GitHub release | downloads from `get.helm.sh` and verifies SHA-256 |
| Cilium | latest stable Cilium GitHub release | reads that release's official Kubernetes compatibility matrix, preflights the OCI chart, then performs Cilium and Ingress validation |
| Local Path Provisioner | existing compatible kind-provided provisioner first; latest Rancher chart only as fallback | validates StorageClass behavior and a real PVC/PV before accepting the storage layer |

## Kubernetes / Cilium Compatibility Guard

The bootstrap does not simply combine the newest kind default Kubernetes image with the newest stable Cilium release.

It resolves versions in this order:

```text
stable Cilium release
        ↓
read its official Kubernetes compatibility matrix
        ↓
latest stable kind release
        ↓
read digest-pinned node images published for that kind release
        ↓
find the intersection
        ↓
select highest compatible Kubernetes patch version
        ↓
create kind explicitly with that image
```

For example, if Cilium lists Kubernetes minors `1.33 1.34 1.35 1.36`, while a kind release publishes node images for `1.37`, `1.36`, `1.35`, and `1.34`, the bootstrap chooses the highest compatible `1.36.x` digest-pinned image rather than the kind default `1.37.x` image.

After the cluster is created, the actual Kubernetes server minor is checked again against Cilium's e2e-tested list before Cilium installation.

An explicit digest-pinned node image can be supplied with:

```text
KIND_NODE_IMAGE
```

An untested Kubernetes minor is rejected by default. `ALLOW_UNTESTED_K8S=true` exists only for intentional experiments where the user explicitly accepts that risk.

## Important Storage Strategy

Modern kind node images can already provide a compatible Local Path Provisioner and the default `standard` StorageClass. Therefore the bootstrap does **not** require a Helm release for storage.

The required behavior is:

```text
StorageClass:        standard
Provisioner:         rancher.io/local-path
Default:             true
ReclaimPolicy:       Delete
VolumeBindingMode:   WaitForFirstConsumer
Provisioner:         Ready
```

The decision is:

```text
Compatible storage already exists?
        |
        +-- yes --> validate it --> use it
        |
        +-- no  --> install latest stable Rancher Local Path chart
                    --> validate it
```

This avoids running a redundant second provisioner with the same `rancher.io/local-path` identity.

The validator reports the detected source, for example:

```text
Storage source: kind-builtin
```

or:

```text
Storage source: helm
```

The real acceptance test is behavior, not installation method.

## kubectl Compatibility Guard

The bootstrap initially installs the current stable kubectl. After kind creates the cluster, it compares the client and API-server versions.

```text
kubectl client minor
        vs
Kubernetes server minor
```

If the difference is outside the supported +/-1 minor skew, the bootstrap installs a kubectl version matching the kind cluster server version.

## Future Cilium and Chart Changes

Lab-specific Cilium values are kept in:

```text
00-prerequisites/cilium-values.yaml
```

Before installing a newly discovered Cilium release, the bootstrap verifies that expected values such as `kubeProxyReplacement`, `envoy`, and `ingressController` still exist and renders the Helm chart against the actual Kubernetes server version.

This Helm-rendering preflight checks the chart/value interface. It is separate from the official Kubernetes/Cilium compatibility check described above.

If a future release changes those assumptions, the bootstrap fails before installation instead of silently producing a different architecture.

The Local Path Helm chart receives the same values/rendering preflight when it is needed as a fallback.

## Visible Wait / Convergence Progress

Kubernetes and Cilium operations are asynchronous. A Pod or Service object can exist before the full dataplane has converged.

Long-running waits therefore show visible progress, for example:

```text
[WAIT] Cilium Helm install/upgrade | (18s)
[WAIT] Cilium Helm install/upgrade / (19s)
[WAIT] Cilium cluster health convergence - (45s/180s)
```

The validator retries Cilium health convergence instead of checking it only once. It also retries the real Ingress HTTP request after the dedicated NodePort Service appears so Envoy/eBPF programming has time to converge.

If Cilium installation fails, the bootstrap prints recent `kube-system` events to make problems such as image extraction or `no space left on device` visible immediately.

## Normal Usage

From an already cloned repository:

```bash
cd ~/kubernetes-learning-lab
bash 00-prerequisites/scripts/bootstrap-lab.sh
```

The sequence is:

```text
Ubuntu validation
      ↓
host capacity preflight
      ↓
base packages
      ↓
repository available
      ↓
resolve stable versions
      ↓
select compatible digest-pinned Kubernetes node image
      ↓
Docker Engine
      ↓
kubectl + kind + Helm
      ↓
kind cluster
      ↓
Cilium
      ↓
Service + Ingress smoke test
      ↓
reuse compatible local storage
      OR
install Local Path fallback
      ↓
PVC/PV read-write smoke test
      ↓
myk8s namespace
      ↓
final validation
```

## Alternative: Run Bootstrap Before Cloning

The preferred method is to install Git and clone the repository first because it is transparent and easy to troubleshoot.

If `curl` is already available, the bootstrap script can also be downloaded directly:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Th3Z3r0/kubernetes-learning-lab/main/00-prerequisites/scripts/bootstrap-lab.sh \
  -o /tmp/bootstrap-lab.sh

bash /tmp/bootstrap-lab.sh
```

In this mode the script installs Git if required and clones the repository to:

```text
~/kubernetes-learning-lab
```

Run the bootstrap as the normal lab user with `sudo` permission, not as root.

## Docker Group Note

A new Docker installation adds the current user to the `docker` group. The bootstrap temporarily re-executes itself with the Docker group when necessary so it can finish the current run. Log out and back in once afterward before using Docker or kind manually from the original shell session.

## Validation Stages

### Host tools

```bash
bash 00-prerequisites/scripts/validate-lab.sh --stage tools
```

Checks binaries, Docker daemon access, and `hello-world`.

### kind bootstrap

```bash
bash 00-prerequisites/scripts/validate-lab.sh --stage kind-bootstrap
```

Checks the 3-node cluster, API reachability, kube-proxy absence, and kubectl/server version skew. Nodes are allowed to be `NotReady` before Cilium is installed.

### Cilium

```bash
bash 00-prerequisites/scripts/validate-lab.sh --stage cilium
```

Checks:

```text
Cilium Helm release
3/3 Nodes Ready
kube-proxy absent
cilium DaemonSet Ready
cilium-envoy DaemonSet Ready
cilium-operator Ready
KubeProxyReplacement=True
Proxy Status=OK
Cluster health=3/3 reachable
IngressClass=cilium
```

Run the active networking test too:

```bash
bash 00-prerequisites/scripts/validate-lab.sh \
  --stage cilium \
  --smoke
```

The smoke test proves both ClusterIP/DNS and Cilium Ingress through a NodePort from the Ubuntu host.

### Storage

```bash
bash 00-prerequisites/scripts/validate-lab.sh --stage storage
```

Static validation checks the required StorageClass properties, identifies the implementation source, and verifies that the local-path Deployment is Ready.

Run the provisioning test:

```bash
bash 00-prerequisites/scripts/validate-lab.sh \
  --stage storage \
  --smoke
```

The smoke test proves:

```text
PVC
 ↓
standard StorageClass
 ↓
rancher.io/local-path
 ↓
PV
 ↓
Pod writes file
 ↓
Pod reads file
 ↓
PVC cleanup
 ↓
PV deleted by ReclaimPolicy=Delete
```

### Complete validation

```bash
bash 00-prerequisites/scripts/validate-lab.sh \
  --stage all \
  --smoke
```

A healthy reference environment should finish with zero failures.

## Safe Rerun Behavior

Normal execution reuses an existing kind cluster and validates it instead of deleting it:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh
```

Recreate the cluster intentionally:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh \
  --recreate-cluster
```

Upgrade Helm-managed components intentionally:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh \
  --upgrade-components
```

A compatible kind-provided/non-Helm storage provisioner is not replaced by this option. The bootstrap keeps it to avoid creating duplicate local-path provisioners.

Prepare only host tools:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh \
  --tools-only
```

Skip active smoke tests:

```bash
bash 00-prerequisites/scripts/bootstrap-lab.sh \
  --no-smoke
```

## Version Overrides

Automatic stable-version discovery is the default, but versions can be pinned for troubleshooting or exact reproduction:

```bash
KUBECTL_VERSION=v1.37.0 \
KIND_VERSION=v0.33.0 \
HELM_VERSION=v4.3.0 \
CILIUM_VERSION=v1.20.1 \
LOCAL_PATH_VERSION=v0.0.37 \
bash 00-prerequisites/scripts/bootstrap-lab.sh \
  --recreate-cluster
```

`LOCAL_PATH_VERSION` is used only when the Helm fallback is needed, or when an existing Helm-managed Local Path installation is explicitly upgraded.

For exact Kubernetes image reproduction, use a digest-pinned node image, for example:

```bash
KIND_NODE_IMAGE='kindest/node:v1.36.4@sha256:<digest>' \
bash 00-prerequisites/scripts/bootstrap-lab.sh \
  --recreate-cluster
```

## State and Log Record

Logs are stored under:

```text
~/.local/state/kubernetes-learning-lab/
```

The most recent resolved/installed state is written to:

```text
~/.local/state/kubernetes-learning-lab/last-bootstrap.env
```

Example:

```text
BOOTSTRAP_TIME=...
UBUNTU_VERSION=...
ARCH=amd64
DOCKER_VERSION=...
KUBECTL_VERSION=...
KIND_VERSION=...
KIND_NODE_IMAGE=kindest/node:v...@sha256:...
KUBERNETES_SERVER_VERSION=...
CILIUM_K8S_SUPPORTED=...
HELM_VERSION=...
CILIUM_VERSION=...
STORAGE_SOURCE=kind-builtin
STORAGE_PROVISIONER=rancher.io/local-path
STORAGE_IMAGE=docker.io/kindest/local-path-provisioner:...
LOCAL_PATH_FALLBACK_VERSION=v0.0.37
CLUSTER_NAME=kind
LAB_DIR=/home/<user>/kubernetes-learning-lab
```

This provides both behaviors we want:

```text
Future new host
    ↓
choose current stable compatible versions

Existing/reproducibility investigation
    ↓
record exactly what was selected and actually used
```

## Safety Decisions

The bootstrap intentionally stops rather than making risky assumptions when it encounters:

- non-Ubuntu operating system
- unsupported CPU architecture
- insufficient free disk or inode capacity
- conflicting pre-existing Docker/container-runtime packages
- failed binary checksum validation
- invalid kubectl/server version skew
- no compatible kind Kubernetes node image for the selected Cilium release
- Kubernetes server minor outside the selected Cilium release's e2e-tested matrix (unless explicitly overridden)
- kube-proxy unexpectedly present
- Cilium chart values no longer matching the lab architecture
- a partial/incompatible existing `standard` StorageClass or local-path Deployment
- a future fallback storage chart no longer matching the lab values
- failed runtime health or smoke validation

A failed validation is part of the design: inspect and correct the incompatible layer rather than continuing with an unknown cluster state.
