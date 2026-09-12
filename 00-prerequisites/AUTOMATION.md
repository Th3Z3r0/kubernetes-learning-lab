# Automated Lab Bootstrap

The manual commands in `LAB.md` are useful for learning and troubleshooting. For a fresh Ubuntu host, the recommended preparation method is the automated bootstrap:

```text
00-prerequisites/scripts/bootstrap-lab.sh
```

A separate validator is provided so every stage can also be checked independently:

```text
00-prerequisites/scripts/validate-lab.sh
```

## Design Goal

The automation is intentionally **future-aware**, not permanently pinned to the versions that happened to be current when this lesson was written.

Default behavior:

```text
Official stable release
        +
checksum / package validation
        +
compatibility preflight
        +
runtime validation
        ↓
install the component
```

The script does **not** interpret "best version" as "blindly install any newest build." It uses stable upstream releases, performs compatibility checks, and stops instead of silently deploying a configuration that no longer matches the lab.

## Version Resolution Strategy

| Component | Default source | Safety behavior |
|---|---|---|
| Docker Engine | Docker official Ubuntu `stable` APT repository | installs/updates the current stable package and validates the daemon with `hello-world` |
| kubectl | Kubernetes `stable.txt` | verifies SHA-256 and checks client/server minor-version skew after kind is created |
| kind | latest non-prerelease GitHub release | verifies the downloaded binary SHA-256 |
| Helm | latest non-prerelease GitHub release | downloads from `get.helm.sh` and verifies SHA-256 |
| Cilium | latest non-prerelease Cilium GitHub release | uses the official OCI Helm chart, checks required values, renders the chart against the cluster Kubernetes version, then performs Cilium and Ingress validation |
| Local Path Provisioner | latest non-prerelease Rancher GitHub release | uses the official OCI Helm chart, preflights the chart, then creates and tests a real PVC/PV |

### kubectl compatibility guard

Kubernetes supports `kubectl` within one minor version of the API server. The bootstrap initially installs the current stable kubectl. After kind creates the cluster, the script compares:

```text
kubectl client minor
        vs
Kubernetes server minor
```

If the difference is greater than one minor, the bootstrap automatically installs a kubectl version matching the kind cluster server version.

### Future Cilium/chart changes

The repository intentionally keeps the lab-specific Cilium values in:

```text
00-prerequisites/cilium-values.yaml
```

Before installing a newly discovered Cilium release, the bootstrap checks that the expected settings still exist and runs `helm template` against the actual Kubernetes server version.

If a future Cilium release changes these values or is not compatible, the bootstrap **fails before installation**. This is preferable to silently creating a cluster with a different architecture.

The same principle is used for the Local Path Provisioner values.

## Normal Usage

From the repository:

```bash
cd ~/kubernetes-learning-lab

chmod +x \
  00-prerequisites/scripts/bootstrap-lab.sh \
  00-prerequisites/scripts/validate-lab.sh

./00-prerequisites/scripts/bootstrap-lab.sh
```

The bootstrap performs the full sequence:

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
Local Path Provisioner
      ↓
PVC/PV read-write smoke test
      ↓
myk8s namespace
      ↓
final validation
```

## Starting From a Completely Fresh Ubuntu Host

The script can also bootstrap the repository itself. Download the bootstrap file to the fresh host and run it as a normal user with `sudo` permission.

Example when `curl` is already available:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Th3Z3r0/kubernetes-learning-lab/main/00-prerequisites/scripts/bootstrap-lab.sh \
  -o /tmp/bootstrap-lab.sh

bash /tmp/bootstrap-lab.sh
```

If the repository does not already exist, the bootstrap installs Git and clones it to:

```text
~/kubernetes-learning-lab
```

The bootstrap must not be run as `root`; run it as the normal lab user and allow it to use `sudo` for host-level installation steps.

## Docker Group Note

A new Docker installation adds the current user to the `docker` group. Linux normally applies new supplementary groups on the next login.

The bootstrap temporarily re-executes itself with the Docker group so it can finish without stopping midway. After the script completes, log out and back in once before using `docker` or `kind` manually from the original shell session.

## Validation After Every Major Stage

The bootstrap calls the validator after each relevant stage. The validator can also be run manually.

### Host tools

```bash
./00-prerequisites/scripts/validate-lab.sh --stage tools
```

Checks include:

```text
curl / git / jq / openssl / tar
Docker CLI + daemon
Docker hello-world
kubectl
kind
Helm
```

### kind bootstrap

```bash
./00-prerequisites/scripts/validate-lab.sh --stage kind-bootstrap
```

Checks include:

```text
kind cluster exists
3 Nodes exist
Kubernetes API reachable
kube-proxy absent
kubectl/server version skew valid
```

`NotReady` Nodes are allowed at this stage before Cilium is installed.

### Cilium

```bash
./00-prerequisites/scripts/validate-lab.sh --stage cilium
```

Checks include:

```text
Cilium Helm release deployed
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

Run the active networking validation too:

```bash
./00-prerequisites/scripts/validate-lab.sh \
  --stage cilium \
  --smoke
```

The smoke test creates temporary resources and proves:

```text
Pod
 ↓
ClusterIP Service + DNS
 ↓
Cilium dataplane
 ↓
backend Pod
```

and:

```text
Ubuntu host
 ↓ NodePort
Cilium Ingress
 ↓ Envoy
Service
 ↓
Pod
```

The temporary namespace is deleted after the test.

### Storage

```bash
./00-prerequisites/scripts/validate-lab.sh --stage storage
```

Checks the expected `standard` StorageClass configuration.

Run the real provisioning test:

```bash
./00-prerequisites/scripts/validate-lab.sh \
  --stage storage \
  --smoke
```

The storage smoke test proves:

```text
PVC
 ↓
standard StorageClass
 ↓
Local Path Provisioner
 ↓
PV
 ↓
Pod writes file
 ↓
Pod reads same file
```

It then deletes the temporary claim and verifies that the dynamically created PV is removed according to `ReclaimPolicy=Delete`.

### Complete validation

```bash
./00-prerequisites/scripts/validate-lab.sh --stage all
```

For the most complete verification:

```bash
./00-prerequisites/scripts/validate-lab.sh \
  --stage all \
  --smoke
```

## Safe Rerun Behavior

The bootstrap is designed to be rerunnable.

If the kind cluster already exists, the default behavior is to **reuse and validate it** rather than delete it.

If Cilium or Local Path Provisioner are already installed in an existing cluster, the bootstrap keeps the installed versions by default rather than unexpectedly upgrading a working lab.

### Recreate the kind cluster intentionally

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --recreate-cluster
```

This deletes the existing kind cluster and its local Kubernetes/PV state before rebuilding it.

### Upgrade already-installed cluster components intentionally

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --upgrade-components
```

This permits Cilium and Local Path Provisioner to be upgraded to the newly resolved stable versions after the compatibility preflight succeeds.

### Prepare only the Ubuntu tools

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --tools-only
```

### Skip active smoke tests

```bash
./00-prerequisites/scripts/bootstrap-lab.sh \
  --no-smoke
```

Static health validation still runs.

## Version Overrides

Automatic stable-version discovery is the default, but every important tool/component can be pinned for troubleshooting or exact reproduction.

Example:

```bash
KUBECTL_VERSION=v1.37.0 \
KIND_VERSION=v0.33.0 \
HELM_VERSION=v4.3.0 \
CILIUM_VERSION=v1.20.1 \
LOCAL_PATH_VERSION=v0.0.37 \
./00-prerequisites/scripts/bootstrap-lab.sh \
  --recreate-cluster
```

Supported override variables:

```text
KUBECTL_VERSION
KIND_VERSION
HELM_VERSION
CILIUM_VERSION
LOCAL_PATH_VERSION
LAB_DIR
CLUSTER_NAME
REPO_URL
```

## Version and Log Record

Each bootstrap run stores logs under:

```text
~/.local/state/kubernetes-learning-lab/
```

The most recently resolved/installed versions are written to:

```text
~/.local/state/kubernetes-learning-lab/last-bootstrap.env
```

Example shape:

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
LOCAL_PATH_VERSION=...
CLUSTER_NAME=kind
LAB_DIR=/home/<user>/kubernetes-learning-lab
```

This gives both behaviors we want:

```text
Future new host
    ↓
automatically choose current stable versions

Existing/reproducibility investigation
    ↓
know exactly which versions were used
```

## Safety Decisions

The script intentionally stops rather than making risky assumptions in these situations:

- non-Ubuntu operating system
- unsupported CPU architecture for this runbook
- conflicting pre-existing Docker/container-runtime packages
- failed binary checksum validation
- invalid kubectl/server version skew
- kube-proxy unexpectedly present
- future Cilium chart values no longer matching the lab architecture
- future storage chart values no longer matching the lab configuration
- failed runtime health or smoke validation

A failed validation is part of the design: fix or review the incompatible step rather than continuing with an unknown lab state.
