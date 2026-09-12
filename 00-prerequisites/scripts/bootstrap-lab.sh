#!/usr/bin/env bash
set -Eeuo pipefail

ORIGINAL_ARGS=("$@")
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_URL="${REPO_URL:-https://github.com/Th3Z3r0/kubernetes-learning-lab.git}"
LAB_DIR="${LAB_DIR:-$HOME/kubernetes-learning-lab}"
CLUSTER_NAME="${CLUSTER_NAME:-kind}"
RECREATE_CLUSTER=false
UPGRADE_COMPONENTS=false
TOOLS_ONLY=false
RUN_SMOKE=true
MIN_FREE_GIB="${MIN_FREE_GIB:-20}"
WARN_FREE_GIB="${WARN_FREE_GIB:-30}"
MIN_FREE_INODES="${MIN_FREE_INODES:-100000}"
ALLOW_UNTESTED_K8S="${ALLOW_UNTESTED_K8S:-false}"

usage() {
  cat <<'USAGE'
Usage: bootstrap-lab.sh [options]

Build the Kubernetes learning lab from a fresh Ubuntu host.
By default, stable releases are discovered from official upstream sources.
The script selects a kind node image whose Kubernetes minor version is listed
as e2e-tested by the selected Cilium release.

Options:
  --recreate-cluster     Delete and recreate the kind cluster if it exists
  --upgrade-components  Upgrade Helm-managed components after preflight
  --tools-only           Install and validate host tools, then stop
  --no-smoke             Skip active network/Ingress and PVC smoke tests
  -h, --help             Show this help

Optional version overrides (environment variables):
  KUBECTL_VERSION        Example: v1.37.0
  KIND_VERSION           Example: v0.33.0
  KIND_NODE_IMAGE        Digest-pinned kindest/node image override
  HELM_VERSION           Example: v4.3.0
  CILIUM_VERSION         Example: v1.20.1 or 1.20.1
  LOCAL_PATH_VERSION     Fallback Helm chart only; example: v0.0.37

Safety overrides:
  MIN_FREE_GIB           Minimum free root disk for a full lab (default: 20)
  WARN_FREE_GIB          Warn below this free root disk value (default: 30)
  MIN_FREE_INODES        Minimum free root inodes (default: 100000)
  ALLOW_UNTESTED_K8S     Set true only to allow a Kubernetes minor that the
                         selected Cilium release does not list as e2e-tested

Other overrides:
  LAB_DIR                Repository location (default: ~/kubernetes-learning-lab)
  CLUSTER_NAME           kind cluster name (default: kind)
  REPO_URL               Git repository URL

The script records the resolved/installed state under:
  ~/.local/state/kubernetes-learning-lab/last-bootstrap.env
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate-cluster)
      RECREATE_CLUSTER=true
      shift
      ;;
    --upgrade-components)
      UPGRADE_COMPONENTS=true
      shift
      ;;
    --tools-only)
      TOOLS_ONLY=true
      shift
      ;;
    --no-smoke)
      RUN_SMOKE=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log()  { printf '\n[BOOTSTRAP] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

progress_indefinite() {
  local label="$1" elapsed="$2" index="$3"
  local frames='|/-\\'
  local frame="${frames:index%4:1}"
  printf '\r[WAIT] %s %s (%ds)' "$label" "$frame" "$elapsed"
}

progress_done() {
  local label="$1" elapsed="$2"
  printf '\r[WAIT] %s done (%ds)%*s\n' "$label" "$elapsed" 20 ''
}

run_with_progress() {
  local label="$1"
  shift
  local output status pid elapsed=0 index=0 rc
  output=$(mktemp)
  status=$(mktemp)
  rm -f "$status"

  (
    set +e
    "$@" >"$output" 2>&1
    printf '%s\n' "$?" >"$status"
  ) &
  pid=$!

  while [[ ! -s "$status" ]]; do
    progress_indefinite "$label" "$elapsed" "$index"
    sleep 1
    elapsed=$((elapsed + 1))
    index=$((index + 1))
  done

  wait "$pid" 2>/dev/null || true
  rc=$(cat "$status")
  progress_done "$label" "$elapsed"
  cat "$output"
  rm -f "$output" "$status"
  return "$rc"
}

on_error() {
  local rc=$?
  printf '\n[FAIL] Bootstrap stopped at line %s (exit %s).\n' "${BASH_LINENO[0]:-unknown}" "$rc" >&2
  printf '[FAIL] Fix the reported step and rerun the script. Completed steps are designed to be idempotent.\n' >&2
  exit "$rc"
}
trap on_error ERR

if [[ "$EUID" -eq 0 ]]; then
  die "Run this script as a normal Ubuntu user with sudo access, not as root."
fi

sudo -v

source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This bootstrap currently supports Ubuntu only. Detected: ${ID:-unknown}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) die "Unsupported architecture for this lab script: $ARCH" ;;
esac

STATE_DIR="$HOME/.local/state/kubernetes-learning-lab"
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

STORAGE_SOURCE="unknown"
STORAGE_PROVISIONER="unknown"
STORAGE_IMAGE="unknown"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
TARGET_KUBERNETES_VERSION="unknown"
CILIUM_K8S_SUPPORTED=""

log "Host: ${PRETTY_NAME:-Ubuntu}; architecture: $ARCH"
info "Log file: $LOG_FILE"

install_base_packages() {
  log "Step 1 - Install base Ubuntu packages"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg git jq openssl tar

  local cmd
  for cmd in curl git jq openssl tar; do
    command -v "$cmd" >/dev/null || die "$cmd was not installed successfully"
  done
  pass "Base packages installed and validated"
}

preflight_host_capacity() {
  log "Preflight - Validate host disk capacity"
  local root_kb avail_kb used_pct total_gib free_gib free_inodes
  read -r root_kb avail_kb used_pct < <(df -Pk / | awk 'NR==2 {print $2, $4, $5}')
  total_gib=$((root_kb / 1024 / 1024))
  free_gib=$((avail_kb / 1024 / 1024))
  free_inodes=$(df -Pi / | awk 'NR==2 {print $4}')

  info "Root filesystem: ${total_gib} GiB total, ${free_gib} GiB free, ${used_pct} used"
  info "Root filesystem free inodes: ${free_inodes}"

  if ! $TOOLS_ONLY && (( free_gib < MIN_FREE_GIB )); then
    die "Only ${free_gib} GiB is free on /. This lab requires at least ${MIN_FREE_GIB} GiB free before kind/Cilium installation."
  fi
  if (( free_gib < WARN_FREE_GIB )); then
    warn "Only ${free_gib} GiB is free on /. ${WARN_FREE_GIB}+ GiB free is recommended for comfortable lab growth."
  else
    pass "Root disk free space is sufficient for the lab"
  fi

  if (( free_inodes < MIN_FREE_INODES )); then
    die "Only ${free_inodes} inodes are free on /. At least ${MIN_FREE_INODES} are required for container image extraction."
  fi
  pass "Root filesystem inode capacity is sufficient"
}

ensure_repository() {
  log "Step 2 - Ensure the learning repository is available"

  local script_repo=""
  script_repo="$(cd "$(dirname "$SELF_PATH")/../.." 2>/dev/null && pwd || true)"
  if [[ -n "$script_repo" && -d "$script_repo/.git" ]]; then
    LAB_DIR="$script_repo"
    pass "Using repository containing this script: $LAB_DIR"
  elif [[ -d "$LAB_DIR/.git" ]]; then
    pass "Using existing repository: $LAB_DIR"
  else
    git clone "$REPO_URL" "$LAB_DIR"
    pass "Repository cloned to $LAB_DIR"
  fi

  if [[ -z "$(git -C "$LAB_DIR" status --porcelain 2>/dev/null)" ]]; then
    git -C "$LAB_DIR" pull --ff-only >/dev/null 2>&1 || warn "Could not fast-forward the repository; continuing with the local checkout"
  else
    warn "Repository has local changes; automatic git pull was skipped"
  fi

  [[ -f "$LAB_DIR/00-prerequisites/kind-config.yaml" ]] || die "Missing kind-config.yaml in $LAB_DIR"
  [[ -f "$LAB_DIR/00-prerequisites/cilium-values.yaml" ]] || die "Missing cilium-values.yaml in $LAB_DIR"
  [[ -f "$LAB_DIR/00-prerequisites/local-path-values.yaml" ]] || die "Missing local-path-values.yaml in $LAB_DIR"
  [[ -f "$LAB_DIR/00-prerequisites/scripts/validate-lab.sh" ]] || die "Missing validate-lab.sh in $LAB_DIR"

  VALIDATOR="$LAB_DIR/00-prerequisites/scripts/validate-lab.sh"
}

github_latest_tag() {
  local repo="$1"
  local effective
  effective=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${repo}/releases/latest")
  basename "$effective"
}

normalize_v() {
  local value="$1"
  [[ "$value" == v* ]] && printf '%s\n' "$value" || printf 'v%s\n' "$value"
}

cilium_supports_minor() {
  local minor="$1"
  tr ' ' '\n' <<<"$CILIUM_K8S_SUPPORTED" | grep -Fxq "$minor"
}

resolve_cilium_kubernetes_matrix() {
  local compat_url compat version_line
  compat_url="https://raw.githubusercontent.com/cilium/cilium/${CILIUM_VERSION}/Documentation/network/kubernetes/compatibility.rst"
  compat=$(curl -fsSL "$compat_url") || die "Could not retrieve Cilium Kubernetes compatibility matrix for ${CILIUM_VERSION}"
  version_line=$(grep -E '^\|[[:space:]]*[0-9]+\.[0-9]+([[:space:]]*,[[:space:]]*[0-9]+\.[0-9]+)+' <<<"$compat" | head -n 1 || true)
  CILIUM_K8S_SUPPORTED=$(grep -oE '[0-9]+\.[0-9]+' <<<"$version_line" | sort -Vu | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
  [[ -n "$CILIUM_K8S_SUPPORTED" ]] || die "Could not parse tested Kubernetes versions from Cilium ${CILIUM_VERSION} compatibility documentation"
  pass "Cilium ${CILIUM_VERSION} e2e-tested Kubernetes minors: ${CILIUM_K8S_SUPPORTED}"
}

select_kind_node_image() {
  local release_json release_body images candidates best version image minor

  if [[ -n "$KIND_NODE_IMAGE" ]]; then
    [[ "$KIND_NODE_IMAGE" =~ ^kindest/node:v([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]] || \
      die "KIND_NODE_IMAGE must be a digest-pinned kindest/node image"
    version="${BASH_REMATCH[1]}"
    minor="${version%.*}"
    if ! cilium_supports_minor "$minor" && [[ "$ALLOW_UNTESTED_K8S" != "true" ]]; then
      die "KIND_NODE_IMAGE uses Kubernetes $minor, but Cilium ${CILIUM_VERSION} lists only: ${CILIUM_K8S_SUPPORTED}. Set ALLOW_UNTESTED_K8S=true only if you intentionally accept this risk."
    fi
    TARGET_KUBERNETES_VERSION="v$version"
    pass "Using explicit kind node image for Kubernetes ${TARGET_KUBERNETES_VERSION}"
    return
  fi

  release_json=$(curl -fsSL "https://api.github.com/repos/kubernetes-sigs/kind/releases/tags/${KIND_VERSION}") || \
    die "Could not retrieve kind ${KIND_VERSION} release metadata"
  release_body=$(jq -r '.body // ""' <<<"$release_json")
  images=$(grep -oE 'kindest/node:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}' <<<"$release_body" | sort -u || true)
  [[ -n "$images" ]] || die "Could not parse digest-pinned node images from kind ${KIND_VERSION} release notes"

  candidates=""
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    version="${image#kindest/node:v}"
    version="${version%%@*}"
    minor="${version%.*}"
    if cilium_supports_minor "$minor"; then
      candidates+="${version} ${image}"$'\n'
    fi
  done <<<"$images"

  best=$(printf '%s' "$candidates" | sed '/^$/d' | sort -V | tail -n 1)
  [[ -n "$best" ]] || die "kind ${KIND_VERSION} does not publish a node image in Cilium ${CILIUM_VERSION}'s tested Kubernetes minors: ${CILIUM_K8S_SUPPORTED}"

  version="${best%% *}"
  KIND_NODE_IMAGE="${best#* }"
  TARGET_KUBERNETES_VERSION="v$version"
  pass "Selected ${KIND_NODE_IMAGE} for Cilium ${CILIUM_VERSION} compatibility"
}

resolve_versions() {
  log "Step 3 - Resolve stable versions and a compatible Kubernetes node image"

  KUBECTL_VERSION="$(normalize_v "${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}")"
  KIND_VERSION="$(normalize_v "${KIND_VERSION:-$(github_latest_tag kubernetes-sigs/kind)}")"
  HELM_VERSION="$(normalize_v "${HELM_VERSION:-$(github_latest_tag helm/helm)}")"
  CILIUM_VERSION="$(normalize_v "${CILIUM_VERSION:-$(github_latest_tag cilium/cilium)}")"
  LOCAL_PATH_VERSION="$(normalize_v "${LOCAL_PATH_VERSION:-$(github_latest_tag rancher/local-path-provisioner)}")"

  local pair
  for pair in \
    "kubectl:$KUBECTL_VERSION" \
    "kind:$KIND_VERSION" \
    "helm:$HELM_VERSION" \
    "cilium:$CILIUM_VERSION" \
    "local-path-fallback:$LOCAL_PATH_VERSION"; do
    [[ "${pair#*:}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+.-][0-9A-Za-z.-]+)?$ ]] || die "Invalid resolved version: $pair"
  done

  resolve_cilium_kubernetes_matrix
  select_kind_node_image

  printf '%-22s %s\n' "kubectl" "$KUBECTL_VERSION"
  printf '%-22s %s\n' "kind" "$KIND_VERSION"
  printf '%-22s %s\n' "kind node image" "$KIND_NODE_IMAGE"
  printf '%-22s %s\n' "Kubernetes target" "$TARGET_KUBERNETES_VERSION"
  printf '%-22s %s\n' "Helm" "$HELM_VERSION"
  printf '%-22s %s\n' "Cilium" "$CILIUM_VERSION"
  printf '%-22s %s\n' "Local Path fallback" "$LOCAL_PATH_VERSION"
  pass "Stable and mutually compatible versions resolved"
}

verify_hash() {
  local file="$1" checksum_url="$2"
  local expected actual
  expected=$(curl -fsSL "$checksum_url" | awk '{print $1}')
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ -n "$expected" && "$actual" == "$expected" ]] || die "SHA-256 validation failed for $file"
}

install_kubectl() {
  local version="$1" tmp installed
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://dl.k8s.io/release/${version}/bin/linux/${ARCH}/kubectl"
  verify_hash "$tmp" "https://dl.k8s.io/release/${version}/bin/linux/${ARCH}/kubectl.sha256"
  sudo install -o root -g root -m 0755 "$tmp" /usr/local/bin/kubectl
  rm -f "$tmp"
  installed=$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')
  [[ "$installed" == "$version" ]] || die "kubectl validation failed: expected $version, got $installed"
  pass "kubectl $installed installed and checksum-validated"
}

install_kind() {
  local version="$1" tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://github.com/kubernetes-sigs/kind/releases/download/${version}/kind-linux-${ARCH}"
  verify_hash "$tmp" "https://github.com/kubernetes-sigs/kind/releases/download/${version}/kind-linux-${ARCH}.sha256sum"
  sudo install -o root -g root -m 0755 "$tmp" /usr/local/bin/kind
  rm -f "$tmp"
  kind version | grep -Fq "$version" || die "kind version validation failed"
  pass "kind $version installed and checksum-validated"
}

install_helm() {
  local version="$1" archive tmpdir installed
  archive="helm-${version}-linux-${ARCH}.tar.gz"
  tmpdir=$(mktemp -d)
  curl -fsSL -o "$tmpdir/$archive" "https://get.helm.sh/$archive"
  verify_hash "$tmpdir/$archive" "https://get.helm.sh/${archive}.sha256sum"
  tar -xzf "$tmpdir/$archive" -C "$tmpdir"
  sudo install -o root -g root -m 0755 "$tmpdir/linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "$tmpdir"
  installed=$(helm version --template '{{ .Version }}')
  [[ "$installed" == "$version" ]] || die "Helm validation failed: expected $version, got $installed"
  pass "Helm $installed installed and checksum-validated"
}

install_docker() {
  log "Step 4 - Install/upgrade Docker Engine from Docker's stable Ubuntu repository"

  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "$codename" ]] || die "Could not determine Ubuntu codename"

  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO

  if ! dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    local conflicts
    conflicts=$(dpkg-query -W -f='${binary:Package} ${Status}\n' \
      docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null \
      | awk '$2=="install" && $3=="ok" && $4=="installed" {print $1}' \
      | tr '\n' ' ' || true)
    if [[ -n "${conflicts// }" ]]; then
      die "Conflicting Docker/container-runtime packages are installed: $conflicts. This bootstrap will not remove existing runtimes automatically."
    fi
  fi

  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable --now docker
  sudo systemctl is-active --quiet docker || die "Docker service is not active"
  sudo docker info >/dev/null
  sudo docker run --rm hello-world >/dev/null
  pass "Docker Engine is running and hello-world succeeded"

  if ! getent group docker | cut -d: -f4 | tr ',' '\n' | grep -Fxq "$USER"; then
    sudo usermod -aG docker "$USER"
    info "Added $USER to the docker group"
  fi

  if ! docker info >/dev/null 2>&1; then
    if [[ "${BOOTSTRAP_DOCKER_GROUP_REEXEC:-0}" == "1" ]]; then
      die "Docker remains inaccessible after refreshing docker group membership"
    fi

    warn "Current shell has not picked up docker group membership yet. Re-executing bootstrap with the docker group for this run."
    local quoted_args="" arg
    for arg in "${ORIGINAL_ARGS[@]}"; do
      printf -v quoted_args '%s %q' "$quoted_args" "$arg"
    done
    exec sg docker -c "BOOTSTRAP_DOCKER_GROUP_REEXEC=1 LAB_DIR=$(printf %q "$LAB_DIR") CLUSTER_NAME=$(printf %q "$CLUSTER_NAME") KIND_NODE_IMAGE=$(printf %q "$KIND_NODE_IMAGE") bash $(printf %q "$SELF_PATH")${quoted_args}"
  fi

  pass "Current bootstrap process can access Docker without sudo"
}

install_cli_tools() {
  log "Step 5 - Install current stable Kubernetes lab CLIs"
  install_kubectl "$KUBECTL_VERSION"
  install_kind "$KIND_VERSION"
  install_helm "$HELM_VERSION"
  bash "$VALIDATOR" --stage tools
}

version_minor_distance() {
  local a="$1" b="$2"
  local amajor aminor bmajor bminor diff
  amajor=$(sed -E 's/^v?([0-9]+)\..*/\1/' <<<"$a")
  aminor=$(sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/' <<<"$a")
  bmajor=$(sed -E 's/^v?([0-9]+)\..*/\1/' <<<"$b")
  bminor=$(sed -E 's/^v?[0-9]+\.([0-9]+).*/\1/' <<<"$b")
  [[ "$amajor" == "$bmajor" ]] || { echo 999; return; }
  diff=$((aminor - bminor))
  (( diff < 0 )) && diff=$((-diff))
  echo "$diff"
}

ensure_kubectl_compatibility() {
  local client server diff
  client=$(kubectl version -o json | jq -r '.clientVersion.gitVersion')
  server=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
  diff=$(version_minor_distance "$client" "$server")

  if (( diff <= 1 )); then
    pass "kubectl $client is compatible with Kubernetes server $server"
  else
    warn "kubectl $client is outside the supported +/-1 minor skew from server $server"
    info "Installing kubectl $server to match the kind cluster"
    install_kubectl "$server"
    KUBECTL_VERSION="$server"
  fi
}

verify_server_cilium_compatibility() {
  local server version minor
  server=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
  version="${server#v}"
  minor="${version%.*}"
  if cilium_supports_minor "$minor"; then
    pass "Kubernetes $server is in Cilium ${CILIUM_VERSION}'s e2e-tested minor list"
  elif [[ "$ALLOW_UNTESTED_K8S" == "true" ]]; then
    warn "Kubernetes $server is outside Cilium ${CILIUM_VERSION}'s e2e-tested minors (${CILIUM_K8S_SUPPORTED}); continuing because ALLOW_UNTESTED_K8S=true"
  else
    die "Kubernetes $server is outside Cilium ${CILIUM_VERSION}'s e2e-tested minors: ${CILIUM_K8S_SUPPORTED}"
  fi
}

ensure_cluster() {
  log "Step 6 - Create or validate the kind cluster"
  NEW_CLUSTER=false

  if kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER_NAME"; then
    if $RECREATE_CLUSTER; then
      warn "Deleting existing kind cluster '$CLUSTER_NAME' because --recreate-cluster was requested"
      kind delete cluster --name "$CLUSTER_NAME"
    else
      info "Existing kind cluster '$CLUSTER_NAME' detected; it will be reused and validated"
    fi
  fi

  if ! kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER_NAME"; then
    info "Creating cluster with node image: $KIND_NODE_IMAGE"
    kind create cluster \
      --name "$CLUSTER_NAME" \
      --config "$LAB_DIR/00-prerequisites/kind-config.yaml" \
      --image "$KIND_NODE_IMAGE"
    NEW_CLUSTER=true
    pass "kind cluster '$CLUSTER_NAME' created"
  fi

  kubectl cluster-info >/dev/null
  ensure_kubectl_compatibility
  verify_server_cilium_compatibility
  bash "$VALIDATOR" --stage kind-bootstrap
}

installed_chart_version() {
  local release="$1" namespace="$2" prefix="$3"
  helm list -n "$namespace" -o json 2>/dev/null \
    | jq -r --arg rel "$release" --arg p "$prefix" '.[] | select(.name==$rel) | .chart | sub("^"+$p+"-"; "")' \
    | head -n 1
}

preflight_cilium_chart() {
  local version="$1"
  local chart="oci://quay.io/cilium/charts/cilium"
  local values server
  values=$(helm show values "$chart" --version "$version")
  grep -Eq '^kubeProxyReplacement:' <<<"$values" || die "Cilium $version no longer exposes kubeProxyReplacement; review the lab values before continuing"
  grep -Eq '^envoy:' <<<"$values" || die "Cilium $version no longer exposes envoy values as expected"
  grep -Eq '^ingressController:' <<<"$values" || die "Cilium $version no longer exposes ingressController values as expected"
  server=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
  helm template cilium "$chart" \
    --version "$version" \
    --namespace kube-system \
    --kube-version "${server#v}" \
    -f "$LAB_DIR/00-prerequisites/cilium-values.yaml" \
    --set k8sServiceHost=127.0.0.1 \
    --set k8sServicePort=6443 >/dev/null
  pass "Cilium $version Helm chart passed values and Kubernetes-version preflight"
}

install_or_validate_cilium() {
  log "Step 7 - Install/validate Cilium"
  local chart="oci://quay.io/cilium/charts/cilium"
  local desired="${CILIUM_VERSION#v}"
  local existing=""
  local control_plane="${CLUSTER_NAME}-control-plane"
  local api_ip

  if helm status cilium -n kube-system >/dev/null 2>&1; then
    existing=$(installed_chart_version cilium kube-system cilium)
  fi

  if [[ -n "$existing" && "$NEW_CLUSTER" == "false" && "$UPGRADE_COMPONENTS" == "false" ]]; then
    info "Cilium $existing is already installed; keeping it. Use --upgrade-components to upgrade to $desired."
    CILIUM_VERSION="v$existing"
    resolve_cilium_kubernetes_matrix
    verify_server_cilium_compatibility
  else
    preflight_cilium_chart "$desired"
    api_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$control_plane")
    [[ -n "$api_ip" ]] || die "Could not discover kind control-plane IP"

    if ! run_with_progress "Cilium Helm install/upgrade" \
      helm upgrade --install cilium "$chart" \
        --version "$desired" \
        --namespace kube-system \
        -f "$LAB_DIR/00-prerequisites/cilium-values.yaml" \
        --set k8sServiceHost="$api_ip" \
        --set k8sServicePort=6443 \
        --wait --timeout 10m; then
      warn "Cilium Helm operation failed. Recent kube-system events:"
      kubectl get events -n kube-system --sort-by=.lastTimestamp 2>/dev/null | tail -n 40 || true
      die "Cilium $desired installation did not complete successfully"
    fi

    pass "Cilium $desired installed"
  fi

  if $RUN_SMOKE; then
    bash "$VALIDATOR" --stage cilium --smoke
  else
    bash "$VALIDATOR" --stage cilium
  fi
}

preflight_local_path_chart() {
  local version="$1"
  local chart="oci://ghcr.io/rancher/local-path-provisioner/charts/local-path-provisioner"
  local values server
  values=$(helm show values "$chart" --version "$version")
  grep -Eq '^storageClass:' <<<"$values" || die "Local Path $version chart does not expose storageClass values as expected"
  grep -Eq '^nodePathMap:' <<<"$values" || die "Local Path $version chart does not expose nodePathMap as expected"
  server=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
  helm template local-path-provisioner "$chart" \
    --version "$version" \
    --namespace local-path-storage \
    --kube-version "${server#v}" \
    -f "$LAB_DIR/00-prerequisites/local-path-values.yaml" >/dev/null
  pass "Local Path $version Helm chart passed values and Kubernetes-version preflight"
}

storage_properties_compatible() {
  kubectl get sc standard >/dev/null 2>&1 || return 1
  [[ "$(kubectl get sc standard -o jsonpath='{.provisioner}' 2>/dev/null)" == "rancher.io/local-path" ]] || return 1
  [[ "$(kubectl get sc standard -o jsonpath='{.reclaimPolicy}' 2>/dev/null)" == "Delete" ]] || return 1
  [[ "$(kubectl get sc standard -o jsonpath='{.volumeBindingMode}' 2>/dev/null)" == "WaitForFirstConsumer" ]] || return 1
  [[ "$(kubectl get sc standard -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)" == "true" ]] || return 1
  kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=5s >/dev/null 2>&1 || return 1
}

detect_storage_source() {
  STORAGE_PROVISIONER=$(kubectl get sc standard -o jsonpath='{.provisioner}' 2>/dev/null || echo unknown)
  STORAGE_IMAGE=$(kubectl get deployment local-path-provisioner -n local-path-storage \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)

  if helm status local-path-provisioner -n local-path-storage >/dev/null 2>&1; then
    STORAGE_SOURCE="helm"
  elif [[ "$STORAGE_IMAGE" == *"kindest/local-path-provisioner:"* ]]; then
    STORAGE_SOURCE="kind-builtin"
  else
    STORAGE_SOURCE="existing-non-helm"
  fi
}

install_or_validate_storage() {
  log "Step 8 - Install/validate dynamic local storage"
  local chart="oci://ghcr.io/rancher/local-path-provisioner/charts/local-path-provisioner"
  local desired="${LOCAL_PATH_VERSION#v}"
  local existing=""

  if storage_properties_compatible; then
    detect_storage_source

    if [[ "$STORAGE_SOURCE" == "helm" && "$UPGRADE_COMPONENTS" == "true" ]]; then
      existing=$(installed_chart_version local-path-provisioner local-path-storage local-path-provisioner)
      info "Upgrading Helm-managed Local Path Provisioner ${existing:-unknown} to $desired"
      preflight_local_path_chart "$desired"
      if ! run_with_progress "Local Path Provisioner Helm upgrade" \
        helm upgrade --install local-path-provisioner "$chart" \
          --version "$desired" \
          --namespace local-path-storage \
          --create-namespace \
          -f "$LAB_DIR/00-prerequisites/local-path-values.yaml" \
          --wait --timeout 5m; then
        die "Local Path Provisioner Helm upgrade failed"
      fi
      STORAGE_SOURCE="helm"
      detect_storage_source
    else
      info "Compatible storage already exists; source=$STORAGE_SOURCE. No redundant provisioner will be installed."
      if [[ "$UPGRADE_COMPONENTS" == "true" && "$STORAGE_SOURCE" != "helm" ]]; then
        info "--upgrade-components does not replace a compatible non-Helm/kind-provided storage provisioner."
      fi
    fi
  else
    if kubectl get sc standard >/dev/null 2>&1 || \
       kubectl get deployment local-path-provisioner -n local-path-storage >/dev/null 2>&1; then
      die "Partial or incompatible local-path storage exists. Refusing to install a second provisioner automatically; inspect StorageClass standard and local-path-storage first."
    fi

    info "No compatible dynamic local storage detected; installing the official Local Path Helm chart as fallback"
    preflight_local_path_chart "$desired"
    if ! run_with_progress "Local Path Provisioner Helm install" \
      helm upgrade --install local-path-provisioner "$chart" \
        --version "$desired" \
        --namespace local-path-storage \
        --create-namespace \
        -f "$LAB_DIR/00-prerequisites/local-path-values.yaml" \
        --wait --timeout 5m; then
      die "Local Path Provisioner Helm installation failed"
    fi
    STORAGE_SOURCE="helm"
    detect_storage_source
    pass "Local Path Provisioner $desired installed as fallback"
  fi

  if $RUN_SMOKE; then
    bash "$VALIDATOR" --stage storage --smoke
  else
    bash "$VALIDATOR" --stage storage
  fi

  detect_storage_source
}

create_namespace() {
  log "Step 9 - Create/validate the myk8s namespace"
  kubectl apply -f "$LAB_DIR/00-prerequisites/manifests/namespace-myk8s.yaml"
  bash "$VALIDATOR" --stage namespace
}

save_state() {
  local server docker_ver
  server=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' || echo unknown)
  docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)

  cat > "$STATE_DIR/last-bootstrap.env" <<STATE
BOOTSTRAP_TIME=$(date -Iseconds)
UBUNTU_VERSION=${VERSION_ID:-unknown}
ARCH=${ARCH}
DOCKER_VERSION=${docker_ver}
KUBECTL_VERSION=${KUBECTL_VERSION}
KIND_VERSION=${KIND_VERSION}
KIND_NODE_IMAGE=${KIND_NODE_IMAGE}
KUBERNETES_SERVER_VERSION=${server}
CILIUM_K8S_SUPPORTED=${CILIUM_K8S_SUPPORTED}
HELM_VERSION=${HELM_VERSION}
CILIUM_VERSION=${CILIUM_VERSION}
STORAGE_SOURCE=${STORAGE_SOURCE}
STORAGE_PROVISIONER=${STORAGE_PROVISIONER}
STORAGE_IMAGE=${STORAGE_IMAGE}
LOCAL_PATH_FALLBACK_VERSION=${LOCAL_PATH_VERSION}
CLUSTER_NAME=${CLUSTER_NAME}
LAB_DIR=${LAB_DIR}
STATE
  pass "Resolved/installed state recorded in $STATE_DIR/last-bootstrap.env"
}

preflight_host_capacity
install_base_packages
ensure_repository
resolve_versions
install_docker
install_cli_tools

if $TOOLS_ONLY; then
  cat > "$STATE_DIR/last-bootstrap.env" <<STATE
BOOTSTRAP_TIME=$(date -Iseconds)
UBUNTU_VERSION=${VERSION_ID:-unknown}
ARCH=${ARCH}
KUBECTL_VERSION=${KUBECTL_VERSION}
KIND_VERSION=${KIND_VERSION}
KIND_NODE_IMAGE=${KIND_NODE_IMAGE}
TARGET_KUBERNETES_VERSION=${TARGET_KUBERNETES_VERSION}
HELM_VERSION=${HELM_VERSION}
CILIUM_VERSION=${CILIUM_VERSION}
CILIUM_K8S_SUPPORTED=${CILIUM_K8S_SUPPORTED}
LAB_DIR=${LAB_DIR}
STATE
  log "Host tool preparation completed successfully"
  warn "If this was the first Docker installation, log out and back in once before using Docker/kind directly from your original shell."
  exit 0
fi

ensure_cluster
install_or_validate_cilium
install_or_validate_storage
create_namespace

log "Step 10 - Final full environment validation"
bash "$VALIDATOR" --stage all
save_state

log "Bootstrap completed successfully"
cat <<SUMMARY

Reference lab is ready:
  kind cluster:       ${CLUSTER_NAME}
  repository:         ${LAB_DIR}
  kind node image:    ${KIND_NODE_IMAGE}
  Kubernetes server:  $(kubectl version -o json | jq -r '.serverVersion.gitVersion')
  Cilium:             ${CILIUM_VERSION}
  Storage source:     ${STORAGE_SOURCE}
  StorageClass:       standard
  Namespace:          myk8s

Validation log:
  ${LOG_FILE}

Version/state record:
  ${STATE_DIR}/last-bootstrap.env
SUMMARY

if [[ "${BOOTSTRAP_DOCKER_GROUP_REEXEC:-0}" == "1" ]]; then
  warn "Docker group membership was refreshed only for this bootstrap process. Log out and back in once before running Docker/kind manually from your original shell."
elif ! id -nG | tr ' ' '\n' | grep -Fxq docker; then
  warn "Your login session does not yet include the docker group. Log out and back in once before running Docker/kind manually."
fi
