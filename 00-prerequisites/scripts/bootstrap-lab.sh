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

usage() {
  cat <<'USAGE'
Usage: bootstrap-lab.sh [options]

Build the Kubernetes learning lab from a fresh Ubuntu host.
By default, stable releases are discovered from official upstream sources.

Options:
  --recreate-cluster     Delete and recreate the kind cluster if it exists
  --upgrade-components  Upgrade Cilium/storage on an existing cluster
  --tools-only           Install and validate host tools, then stop
  --no-smoke             Skip active network/Ingress and PVC smoke tests
  -h, --help             Show this help

Optional version overrides (environment variables):
  KUBECTL_VERSION        Example: v1.37.0
  KIND_VERSION           Example: v0.33.0
  HELM_VERSION           Example: v4.3.0
  CILIUM_VERSION         Example: v1.20.1 or 1.20.1
  LOCAL_PATH_VERSION     Example: v0.0.37 or 0.0.37

Other overrides:
  LAB_DIR                Repository location (default: ~/kubernetes-learning-lab)
  CLUSTER_NAME           kind cluster name (default: kind)
  REPO_URL               Git repository URL

The script records the resolved versions under:
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

log "Host: ${PRETTY_NAME:-Ubuntu}; architecture: $ARCH"
info "Log file: $LOG_FILE"

install_base_packages() {
  log "Step 1 - Install base Ubuntu packages"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    git \
    jq \
    openssl \
    tar

  command -v curl >/dev/null
  command -v git >/dev/null
  command -v jq >/dev/null
  command -v openssl >/dev/null
  command -v tar >/dev/null
  pass "Base packages installed"
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
  chmod +x "$VALIDATOR" 2>/dev/null || true
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

resolve_versions() {
  log "Step 3 - Resolve current stable versions from official sources"

  KUBECTL_VERSION="$(normalize_v "${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}")"
  KIND_VERSION="$(normalize_v "${KIND_VERSION:-$(github_latest_tag kubernetes-sigs/kind)}")"
  HELM_VERSION="$(normalize_v "${HELM_VERSION:-$(github_latest_tag helm/helm)}")"
  CILIUM_VERSION="$(normalize_v "${CILIUM_VERSION:-$(github_latest_tag cilium/cilium)}")"
  LOCAL_PATH_VERSION="$(normalize_v "${LOCAL_PATH_VERSION:-$(github_latest_tag rancher/local-path-provisioner)}")"

  for pair in \
    "kubectl:$KUBECTL_VERSION" \
    "kind:$KIND_VERSION" \
    "helm:$HELM_VERSION" \
    "cilium:$CILIUM_VERSION" \
    "local-path:$LOCAL_PATH_VERSION"; do
    [[ "${pair#*:}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+.-][0-9A-Za-z.-]+)?$ ]] || die "Invalid resolved version: $pair"
  done

  printf '%-18s %s\n' "kubectl" "$KUBECTL_VERSION"
  printf '%-18s %s\n' "kind" "$KIND_VERSION"
  printf '%-18s %s\n' "Helm" "$HELM_VERSION"
  printf '%-18s %s\n' "Cilium" "$CILIUM_VERSION"
  printf '%-18s %s\n' "Local Path" "$LOCAL_PATH_VERSION"

  pass "Stable versions resolved"
}

verify_hash() {
  local file="$1"
  local checksum_url="$2"
  local expected actual
  expected=$(curl -fsSL "$checksum_url" | awk '{print $1}')
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ -n "$expected" && "$actual" == "$expected" ]] || die "SHA-256 validation failed for $file"
}

install_kubectl() {
  local version="$1"
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://dl.k8s.io/release/${version}/bin/linux/${ARCH}/kubectl"
  verify_hash "$tmp" "https://dl.k8s.io/release/${version}/bin/linux/${ARCH}/kubectl.sha256"
  sudo install -o root -g root -m 0755 "$tmp" /usr/local/bin/kubectl
  rm -f "$tmp"

  local installed
  installed=$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')
  [[ "$installed" == "$version" ]] || die "kubectl validation failed: expected $version, got $installed"
  pass "kubectl $installed installed and checksum-validated"
}

install_kind() {
  local version="$1"
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://github.com/kubernetes-sigs/kind/releases/download/${version}/kind-linux-${ARCH}"
  verify_hash "$tmp" "https://github.com/kubernetes-sigs/kind/releases/download/${version}/kind-linux-${ARCH}.sha256sum"
  sudo install -o root -g root -m 0755 "$tmp" /usr/local/bin/kind
  rm -f "$tmp"

  kind version | grep -Fq "$version" || die "kind version validation failed"
  pass "kind $version installed and checksum-validated"
}

install_helm() {
  local version="$1"
  local archive="helm-${version}-linux-${ARCH}.tar.gz"
  local tmpdir
  tmpdir=$(mktemp -d)
  curl -fsSL -o "$tmpdir/$archive" "https://get.helm.sh/$archive"
  verify_hash "$tmpdir/$archive" "https://get.helm.sh/${archive}.sha256sum"
  tar -xzf "$tmpdir/$archive" -C "$tmpdir"
  sudo install -o root -g root -m 0755 "$tmpdir/linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "$tmpdir"

  local installed
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
      | awk '$3=="install" && $4=="ok" && $5=="installed" {print $1}' \
      | tr '\n' ' ' || true)
    if [[ -n "${conflicts// }" ]]; then
      die "Conflicting Docker/container-runtime packages are installed: $conflicts. This fresh-host bootstrap will not remove existing runtimes automatically."
    fi
  fi

  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  sudo systemctl enable --now docker
  sudo systemctl is-active --quiet docker || die "Docker service is not active"
  sudo docker info >/dev/null
  sudo docker run --rm hello-world >/dev/null
  pass "Docker Engine is running and hello-world succeeded"

  if ! getent group docker | grep -Eq "[,:]${USER}(,|$)"; then
    sudo usermod -aG docker "$USER"
    info "Added $USER to the docker group"
  fi

  if ! docker info >/dev/null 2>&1; then
    if [[ "${BOOTSTRAP_DOCKER_GROUP_REEXEC:-0}" == "1" ]]; then
      die "Docker remains inaccessible after refreshing docker group membership"
    fi

    warn "Current shell has not picked up docker group membership yet. Re-executing bootstrap with the docker group for this run."
    local quoted_args=""
    local arg
    for arg in "${ORIGINAL_ARGS[@]}"; do
      printf -v quoted_args '%s %q' "$quoted_args" "$arg"
    done
    exec sg docker -c "BOOTSTRAP_DOCKER_GROUP_REEXEC=1 LAB_DIR=$(printf %q "$LAB_DIR") CLUSTER_NAME=$(printf %q "$CLUSTER_NAME") bash $(printf %q "$SELF_PATH")${quoted_args}"
  fi

  pass "Current bootstrap process can access Docker without sudo"
}

install_cli_tools() {
  log "Step 5 - Install latest stable Kubernetes lab CLIs"
  install_kubectl "$KUBECTL_VERSION"
  install_kind "$KIND_VERSION"
  install_helm "$HELM_VERSION"
  "$VALIDATOR" --stage tools
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
    kind create cluster \
      --name "$CLUSTER_NAME" \
      --config "$LAB_DIR/00-prerequisites/kind-config.yaml"
    NEW_CLUSTER=true
    pass "kind cluster '$CLUSTER_NAME' created"
  fi

  kubectl cluster-info >/dev/null
  ensure_kubectl_compatibility
  "$VALIDATOR" --stage kind-bootstrap
}

installed_chart_version() {
  local release="$1" namespace="$2" prefix="$3"
  helm list -n "$namespace" -o json 2>/dev/null | jq -r --arg rel "$release" --arg p "$prefix" '.[] | select(.name==$rel) | .chart | sub("^"+$p+"-"; "")' | head -n 1
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
  else
    preflight_cilium_chart "$desired"
    api_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$control_plane")
    [[ -n "$api_ip" ]] || die "Could not discover kind control-plane IP"

    helm upgrade --install cilium "$chart" \
      --version "$desired" \
      --namespace kube-system \
      -f "$LAB_DIR/00-prerequisites/cilium-values.yaml" \
      --set k8sServiceHost="$api_ip" \
      --set k8sServicePort=6443 \
      --wait \
      --timeout 10m

    pass "Cilium $desired installed"
  fi

  if $RUN_SMOKE; then
    "$VALIDATOR" --stage cilium --smoke
  else
    "$VALIDATOR" --stage cilium
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

install_or_validate_storage() {
  log "Step 8 - Install/validate dynamic local storage"
  local chart="oci://ghcr.io/rancher/local-path-provisioner/charts/local-path-provisioner"
  local desired="${LOCAL_PATH_VERSION#v}"
  local existing=""

  if helm status local-path-provisioner -n local-path-storage >/dev/null 2>&1; then
    existing=$(installed_chart_version local-path-provisioner local-path-storage local-path-provisioner)
  fi

  if [[ -n "$existing" && "$NEW_CLUSTER" == "false" && "$UPGRADE_COMPONENTS" == "false" ]]; then
    info "Local Path Provisioner $existing is already installed; keeping it. Use --upgrade-components to upgrade to $desired."
    LOCAL_PATH_VERSION="v$existing"
  else
    preflight_local_path_chart "$desired"
    helm upgrade --install local-path-provisioner "$chart" \
      --version "$desired" \
      --namespace local-path-storage \
      --create-namespace \
      -f "$LAB_DIR/00-prerequisites/local-path-values.yaml" \
      --wait \
      --timeout 5m
    pass "Local Path Provisioner $desired installed"
  fi

  if $RUN_SMOKE; then
    "$VALIDATOR" --stage storage --smoke
  else
    "$VALIDATOR" --stage storage
  fi
}

create_namespace() {
  log "Step 9 - Create/validate the myk8s namespace"
  kubectl apply -f "$LAB_DIR/00-prerequisites/manifests/namespace-myk8s.yaml"
  "$VALIDATOR" --stage namespace
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
KUBERNETES_SERVER_VERSION=${server}
HELM_VERSION=${HELM_VERSION}
CILIUM_VERSION=${CILIUM_VERSION}
LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION}
CLUSTER_NAME=${CLUSTER_NAME}
LAB_DIR=${LAB_DIR}
STATE
  pass "Resolved/installed versions recorded in $STATE_DIR/last-bootstrap.env"
}

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
HELM_VERSION=${HELM_VERSION}
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
"$VALIDATOR" --stage all
save_state

log "Bootstrap completed successfully"
cat <<SUMMARY

Reference lab is ready:
  kind cluster:       ${CLUSTER_NAME}
  repository:         ${LAB_DIR}
  Kubernetes server:  $(kubectl version -o json | jq -r '.serverVersion.gitVersion')
  Cilium:             ${CILIUM_VERSION}
  StorageClass:       standard
  Namespace:          myk8s

Validation log:
  ${LOG_FILE}

Version record:
  ${STATE_DIR}/last-bootstrap.env
SUMMARY

if [[ "${BOOTSTRAP_DOCKER_GROUP_REEXEC:-0}" == "1" ]]; then
  warn "Docker group membership was refreshed only for this bootstrap process. Log out and back in once before running Docker/kind manually from your original shell."
elif ! id -nG | tr ' ' '\n' | grep -Fxq docker; then
  warn "Your login session does not yet include the docker group. Log out and back in once before running Docker/kind manually."
fi
