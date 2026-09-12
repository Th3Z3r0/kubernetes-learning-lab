# Automated Lab Bootstrap

The manual commands in `LAB.md` are useful for learning and troubleshooting. For a fresh Ubuntu host, the recommended preparation method is:

```text
00-prerequisites/scripts/bootstrap-lab.sh
```

A separate validator checks each stage independently:

```text
00-prerequisites/scripts/validate-lab.sh
```

## Design Goal

The automation is future-aware rather than permanently pinned to the versions that happened to be current when the lab was written.

```text
Official stable release
        +
checksum / package validation
        +
compatibility preflight
        +
runtime validation
        ↓
use or install the component
```

"Best version" does not mean blindly installing the newest artifact. The bootstrap discovers stable upstream releases, checks compatibility, validates the resulting behavior, and stops when a future change no longer matches the lab architecture.

## Version Resolution Strategy

| Component | Default source | Safety behavior |
|---|---|---|
| Docker Engine | Docker official Ubuntu `stable` APT repository | installs/updates the stable package and validates the daemon with `hello-world` |
| kubectl | Kubernetes `stable.txt` | verifies SHA-256 and checks client/server minor-version skew after kind is created |
| kind | latest stable GitHub release | verifies the downloaded binary SHA-256 |
| Helm | latest stable GitHub release | downloads from `get.helm.sh` and verifies SHA-256 |
| Cilium | latest stable Cilium GitHub release | preflights the official OCI chart against the cluster Kubernetes version, then performs Cilium and Ingress validation |
| Local Path Provisioner | existing compatible kind-provided provisioner first; latest Rancher chart only as fallback | validates StorageClass behavior and a real PVC/PV before accepting the storage layer |

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

If a future release changes those assumptions, the bootstrap fails before installation instead of silently producing a different architecture.

The Local Path Helm chart receives the same preflight when it is needed as a fallback.

## Normal Usage

From the repository:

```bash
cd ~/kubernetes-learning-lab

chmod +x \
  00-prerequisites/scripts/bootstrap-lab.sh \
  00-prerequisites/scripts/validate-lab.sh

./00-prerequisites/scripts/bootstrap-lab.sh
```

The sequence is:

```text
Ubuntu validation
      ↓
base packages
      ↓
repository available
      ↓
resolve stable versions
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

## Starting From a Fresh Ubuntu Host

If `curl` is already available:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Th3Z3r0/kubernetes-learning-lab/main/00-prerequisites/scripts/bootstrap-lab.sh \
  -o /tmp/bootstrap-lab.sh

bash /tmp/bootstrap-lab.sh
```

The script installs Git if required and clones the repository to:

```text
~/kubernetes-learning-lab
```

Run the bootstrap as the normal lab user with `sudo` permission, not as root.

## Docker Group Note

A new Docker installation adds the current user to the `docker` group. The bootstrap temporarily re-executes itself with the Docker group when necessary so it can finish the current run. Log out and back in once afterward before using Docker or kind manually from the original shell session.

## Validation Stages

### Host tools

```bash
./00-prerequisites/scripts/validate-lab.sh --stage tools
```

Checks binaries, Docker daemon access, and `hello-world`.

### kind bootstrap

```bash
./00-prerequisites/scripts/validate-lab.sh --stage kind-bootstrap
```

Checks the 3-node cluster, API reachability, kube-proxy absence, and kubectl/server version skew. Nodes are allowed to be `NotReady` before Cilium is installed.

### Cilium

```bash
./00-prerequisites/scripts/validate-lab.sh --stage cilium
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
./00-prerequisites/scripts/validate-lab.sh \
  --stage cilium \
  --smoke
```

The smoke test proves both ClusterIP/DNS and Cilium Ingress through a NodePort from the Ubuntu host.

### Storage

```bash
./00-prerequisites/scripts/validate-lab.sh --stage storage
```

Static validation checks the required StorageClass properties, identifies the implementation source, and verifies that the local-path Deployment is Ready.

Run the provisioning test:

```bash
./00-prerequisites/scripts/validate-lab.sh \
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
./00-prerequisites/scripts/validate-lab.sh \
  --stage all \
  --smoke
```

A healthy reference environment should finish with zero failures.

## Safe Rerun Behavior

Normal execution reuses an existing kind cluster and validates it instead of deleting it:

```bash
./00-prerequisites/scripts/bootstrap-lab.sh
```

Recreate the cluster intentionally:

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --recreate-cluster
```

Upgrade Helm-managed components intentionally:

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --upgrade-components
```

A compatible kind-provided/non-Helm storage provisioner is not replaced by this option. The bootstrap keeps it to avoid creating duplicate local-path provisioners.

Prepare only host tools:

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --tools-only
```

Skip active smoke tests:

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --no-smoke
```

## Version Overrides

Automatic stable-version discovery is the default, but versions can be pinned for troubleshooting or exact reproduction:

```bash
KUBECTL_VERSION=v1.36.3 \
KIND_VERSION=v0.33.0 \
HELM_VERSION=v4.3.0 \
CILIUM_VERSION=v1.20.1 \
LOCAL_PATH_VERSION=v0.0.37 \
./00-prerequisites/scripts/bootstrap-lab.sh \
  --recreate-cluster
```

`LOCAL_PATH_VERSION` is used only when the Helm fallback is needed, or when an existing Helm-managed Local Path installation is explicitly upgraded.

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
KUBERNETES_SERVER_VERSION=...
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
- conflicting pre-existing Docker/container-runtime packages
- failed binary checksum validation
- invalid kubectl/server version skew
- kube-proxy unexpectedly present
- Cilium chart values no longer matching the lab architecture
- a partial/incompatible existing `standard` StorageClass or local-path Deployment
- a future fallback storage chart no longer matching the lab values
- failed runtime health or smoke validation

A failed validation is part of the design: inspect and correct the incompatible layer rather than continuing with an unknown cluster state.
