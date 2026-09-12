#!/usr/bin/env bash
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kind}"
RUN_SMOKE=false
STAGE="all"
FAILURES=0
PASSES=0

usage() {
  cat <<'USAGE'
Usage: validate-lab.sh [--stage STAGE] [--smoke]

Stages:
  tools           Validate host tools and Docker
  kind-bootstrap  Validate the kind cluster bootstrap state
  cilium          Validate Cilium, kube-proxy replacement, and Ingress
  storage         Validate compatible dynamic local storage
  namespace       Validate the myk8s namespace
  all             Validate the complete final environment (default)

Options:
  --smoke         Run active network/Ingress and storage smoke tests
  -h, --help      Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      STAGE="${2:-}"
      shift 2
      ;;
    --smoke)
      RUN_SMOKE=true
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

pass() {
  printf '[PASS] %s\n' "$1"
  PASSES=$((PASSES + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

info() {
  printf '[INFO] %s\n' "$1"
}

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 is installed: $(command -v "$1")"
  else
    fail "$1 is not installed"
  fi
}

validate_tools() {
  info "Validating host tools"
  local cmd
  for cmd in curl git jq openssl tar docker kubectl kind helm; do
    check_cmd "$cmd"
  done

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      pass "Docker daemon is reachable by the current user"
    else
      fail "Docker daemon is not reachable by the current user"
    fi

    if docker run --rm hello-world >/dev/null 2>&1; then
      pass "Docker hello-world container runs successfully"
    else
      fail "Docker hello-world container failed"
    fi
  fi

  command -v kubectl >/dev/null 2>&1 && info "$(kubectl version --client 2>/dev/null | head -n 1)"
  command -v kind >/dev/null 2>&1 && info "$(kind version 2>/dev/null)"
  command -v helm >/dev/null 2>&1 && info "$(helm version --short 2>/dev/null || helm version 2>/dev/null | head -n 1)"
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

validate_kind_bootstrap() {
  info "Validating kind cluster bootstrap"

  if ! command -v kind >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
    fail "kind and kubectl are required for cluster validation"
    return
  fi

  if kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER_NAME"; then
    pass "kind cluster '$CLUSTER_NAME' exists"
  else
    fail "kind cluster '$CLUSTER_NAME' does not exist"
    return
  fi

  local node_count
  node_count=$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$node_count" == "3" ]]; then
    pass "kind cluster has 3 nodes"
  else
    fail "expected 3 kind nodes, found $node_count"
  fi

  if kubectl cluster-info >/dev/null 2>&1; then
    pass "Kubernetes API server is reachable"
  else
    fail "Kubernetes API server is not reachable"
    return
  fi

  if kubectl get ds kube-proxy -n kube-system >/dev/null 2>&1; then
    fail "kube-proxy exists; reference lab expects kube-proxy to be absent"
  else
    pass "kube-proxy is absent"
  fi

  local total ready
  total=$(kubectl get nodes -o json 2>/dev/null | jq '.items | length' 2>/dev/null || echo 0)
  ready=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo 0)
  info "Node readiness: ${ready}/${total} Ready"

  local client server diff
  client=$(kubectl version -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty')
  server=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty')
  if [[ -n "$client" && -n "$server" ]]; then
    diff=$(version_minor_distance "$client" "$server")
    if (( diff <= 1 )); then
      pass "kubectl $client is within one minor of server $server"
    else
      fail "kubectl $client is outside the supported +/-1 minor skew from server $server"
    fi
  else
    fail "could not determine kubectl client/server versions"
  fi
}

validate_cilium_static() {
  info "Validating Cilium"

  if ! helm status cilium -n kube-system >/dev/null 2>&1; then
    fail "Cilium Helm release is not deployed"
    return 1
  fi
  pass "Cilium Helm release is deployed"

  local total ready
  total=$(kubectl get nodes -o json 2>/dev/null | jq '.items | length' 2>/dev/null || echo 0)
  ready=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo 0)
  if [[ "$total" == "3" && "$ready" == "3" ]]; then
    pass "all 3 Kubernetes nodes are Ready"
  else
    fail "expected 3/3 Ready nodes, found ${ready}/${total}"
  fi

  if kubectl get ds kube-proxy -n kube-system >/dev/null 2>&1; then
    fail "kube-proxy exists"
  else
    pass "kube-proxy remains absent"
  fi

  local ds desired ready_ds
  for ds in cilium cilium-envoy; do
    desired=$(kubectl get ds "$ds" -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    ready_ds=$(kubectl get ds "$ds" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    if [[ -n "$desired" && "$desired" != "0" && "$desired" == "$ready_ds" ]]; then
      pass "$ds DaemonSet is Ready (${ready_ds}/${desired})"
    else
      fail "$ds DaemonSet is not fully Ready (${ready_ds:-0}/${desired:-0})"
    fi
  done

  if kubectl rollout status deployment/cilium-operator -n kube-system --timeout=5s >/dev/null 2>&1; then
    pass "cilium-operator Deployment is Ready"
  else
    fail "cilium-operator Deployment is not Ready"
  fi

  local status
  status=$(kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null || true)
  if grep -Eq 'KubeProxyReplacement:[[:space:]]+True' <<<"$status"; then
    pass "Cilium kube-proxy replacement is enabled"
  else
    fail "Cilium kube-proxy replacement is not reported as True"
  fi
  if grep -Eq 'Proxy Status:[[:space:]]+OK' <<<"$status"; then
    pass "Cilium proxy status is OK"
  else
    fail "Cilium proxy status is not OK"
  fi
  if grep -Eq 'Cluster health:[[:space:]]+3/3 reachable' <<<"$status"; then
    pass "Cilium cluster health is 3/3 reachable"
  else
    fail "Cilium cluster health is not 3/3 reachable"
  fi

  if kubectl get ingressclass cilium >/dev/null 2>&1; then
    pass "Cilium IngressClass exists"
  else
    fail "Cilium IngressClass does not exist"
  fi
}

network_smoke_test() {
  info "Running active Cilium Service and Ingress smoke test"
  local ns="bootstrap-netcheck-$$"
  local node node_ip ingress_svc node_port i

  kubectl create namespace "$ns" >/dev/null 2>&1 || { fail "could not create network smoke-test namespace"; return; }

  cleanup_network() {
    kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
  }

  if ! cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ${ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: ${ns}
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: ${ns}
spec:
  containers:
    - name: client
      image: curlimages/curl:latest
      command: ["sh", "-c", "sleep 600"]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bootstrap-ingress
  namespace: ${ns}
  annotations:
    ingress.cilium.io/loadbalancer-mode: dedicated
    ingress.cilium.io/service-type: NodePort
spec:
  ingressClassName: cilium
  rules:
    - host: bootstrap.myk8s.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
YAML
  then
    fail "could not create network smoke-test resources"
    cleanup_network
    return
  fi

  if kubectl rollout status deployment/web -n "$ns" --timeout=180s >/dev/null 2>&1 && \
     kubectl wait --for=condition=Ready pod/client -n "$ns" --timeout=180s >/dev/null 2>&1; then
    pass "network smoke-test Pods are Ready"
  else
    fail "network smoke-test Pods did not become Ready"
    cleanup_network
    return
  fi

  if kubectl exec -n "$ns" client -- curl -fsS http://web >/dev/null 2>&1; then
    pass "ClusterIP Service and cluster DNS are working through Cilium"
  else
    fail "ClusterIP Service/DNS smoke test failed"
  fi

  ingress_svc=""
  for i in $(seq 1 60); do
    ingress_svc=$(kubectl get svc -n "$ns" -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="NodePort" and (.metadata.name | startswith("cilium-ingress"))) | .metadata.name' | head -n 1)
    [[ -n "$ingress_svc" ]] && break
    sleep 2
  done

  if [[ -z "$ingress_svc" ]]; then
    fail "Cilium did not create a dedicated Ingress NodePort Service"
    cleanup_network
    return
  fi
  pass "Cilium created dedicated Ingress Service $ingress_svc"

  node_port=$(kubectl get svc "$ingress_svc" -n "$ns" -o json | jq -r '.spec.ports[] | select(.port==80) | .nodePort')
  node="${CLUSTER_NAME}-worker"
  node_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$node" 2>/dev/null || true)

  if [[ -n "$node_ip" && -n "$node_port" ]] && curl -fsS --connect-timeout 5 -H 'Host: bootstrap.myk8s.local' "http://${node_ip}:${node_port}/" >/dev/null 2>&1; then
    pass "Cilium Ingress works through NodePort from the Ubuntu host"
  else
    fail "Cilium Ingress NodePort smoke test failed"
  fi

  cleanup_network
}

detect_storage_source() {
  STORAGE_SOURCE="unknown"
  STORAGE_IMAGE=""

  if helm status local-path-provisioner -n local-path-storage >/dev/null 2>&1; then
    STORAGE_SOURCE="helm"
  fi

  if kubectl get deployment local-path-provisioner -n local-path-storage >/dev/null 2>&1; then
    STORAGE_IMAGE=$(kubectl get deployment local-path-provisioner -n local-path-storage \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

    if [[ "$STORAGE_SOURCE" != "helm" ]]; then
      if [[ "$STORAGE_IMAGE" == *"kindest/local-path-provisioner:"* ]]; then
        STORAGE_SOURCE="kind-builtin"
      else
        STORAGE_SOURCE="existing-non-helm"
      fi
    fi
  fi
}

validate_storage_static() {
  info "Validating compatible dynamic local storage"

  if ! kubectl get storageclass standard >/dev/null 2>&1; then
    fail "StorageClass standard does not exist"
    return 1
  fi
  pass "StorageClass standard exists"

  local provisioner reclaim binding default_class
  provisioner=$(kubectl get sc standard -o jsonpath='{.provisioner}' 2>/dev/null)
  reclaim=$(kubectl get sc standard -o jsonpath='{.reclaimPolicy}' 2>/dev/null)
  binding=$(kubectl get sc standard -o jsonpath='{.volumeBindingMode}' 2>/dev/null)
  default_class=$(kubectl get sc standard -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)

  [[ "$provisioner" == "rancher.io/local-path" ]] && pass "standard uses rancher.io/local-path" || fail "unexpected provisioner: $provisioner"
  [[ "$reclaim" == "Delete" ]] && pass "standard reclaimPolicy is Delete" || fail "unexpected reclaimPolicy: $reclaim"
  [[ "$binding" == "WaitForFirstConsumer" ]] && pass "standard volumeBindingMode is WaitForFirstConsumer" || fail "unexpected volumeBindingMode: $binding"
  [[ "$default_class" == "true" ]] && pass "standard is the default StorageClass" || fail "standard is not marked as default"

  detect_storage_source
  info "Storage source: $STORAGE_SOURCE${STORAGE_IMAGE:+; image: $STORAGE_IMAGE}"

  if kubectl get deployment local-path-provisioner -n local-path-storage >/dev/null 2>&1 && \
     kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=5s >/dev/null 2>&1; then
    pass "Local Path Provisioner Deployment is Ready"
  else
    fail "Local Path Provisioner Deployment is not Ready or not found"
  fi

  case "$STORAGE_SOURCE" in
    helm)
      pass "Local Path Provisioner is Helm-managed"
      ;;
    kind-builtin)
      pass "compatible kind-provided Local Path Provisioner detected"
      ;;
    existing-non-helm)
      pass "compatible non-Helm Local Path Provisioner detected"
      ;;
    *)
      fail "could not identify the Local Path Provisioner source"
      ;;
  esac
}

storage_smoke_test() {
  info "Running active dynamic-storage smoke test"
  local ns="bootstrap-storage-check-$$"
  local pv=""
  local i

  kubectl create namespace "$ns" >/dev/null 2>&1 || { fail "could not create storage smoke-test namespace"; return; }

  cleanup_storage() {
    kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
  }

  if ! cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-pvc
  namespace: ${ns}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 16Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-client
  namespace: ${ns}
spec:
  containers:
    - name: storage-client
      image: busybox:latest
      command: ["sh", "-c", "echo storage-ok > /data/proof.txt; sleep 600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: smoke-pvc
YAML
  then
    fail "could not create storage smoke-test resources"
    cleanup_storage
    return
  fi

  if kubectl wait --for=condition=Ready pod/storage-client -n "$ns" --timeout=180s >/dev/null 2>&1; then
    pass "PVC consumer Pod became Ready"
  else
    fail "PVC consumer Pod did not become Ready"
    cleanup_storage
    return
  fi

  if [[ "$(kubectl get pvc smoke-pvc -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Bound" ]]; then
    pass "dynamic PVC is Bound"
  else
    fail "dynamic PVC is not Bound"
  fi

  if [[ "$(kubectl exec -n "$ns" storage-client -- cat /data/proof.txt 2>/dev/null)" == "storage-ok" ]]; then
    pass "data can be written to and read from the dynamically provisioned volume"
  else
    fail "dynamic volume read/write test failed"
  fi

  pv=$(kubectl get pv -o json 2>/dev/null | jq -r --arg ns "$ns" '.items[] | select(.spec.claimRef.namespace==$ns and .spec.claimRef.name=="smoke-pvc") | .metadata.name' | head -n 1)
  cleanup_storage

  if [[ -n "$pv" ]]; then
    for i in $(seq 1 30); do
      if ! kubectl get pv "$pv" >/dev/null 2>&1; then
        pass "PV was deleted after PVC cleanup (reclaimPolicy Delete)"
        return
      fi
      sleep 2
    done
    fail "PV $pv still exists after cleanup"
  else
    fail "could not identify the dynamically provisioned PV"
  fi
}

validate_namespace() {
  info "Validating lab namespace"
  if [[ "$(kubectl get namespace myk8s -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Active" ]]; then
    pass "namespace myk8s is Active"
  else
    fail "namespace myk8s is not Active"
  fi

  if [[ "$(kubectl auth can-i create pods -n myk8s 2>/dev/null || true)" == "yes" ]]; then
    pass "current identity can create Pods in myk8s"
  else
    fail "current identity cannot create Pods in myk8s"
  fi
}

case "$STAGE" in
  tools)
    validate_tools
    ;;
  kind-bootstrap)
    validate_kind_bootstrap
    ;;
  cilium)
    validate_kind_bootstrap
    validate_cilium_static
    $RUN_SMOKE && network_smoke_test
    ;;
  storage)
    validate_storage_static
    $RUN_SMOKE && storage_smoke_test
    ;;
  namespace)
    validate_namespace
    ;;
  all)
    validate_tools
    validate_kind_bootstrap
    validate_cilium_static
    validate_storage_static
    validate_namespace
    if $RUN_SMOKE; then
      network_smoke_test
      storage_smoke_test
    fi
    ;;
  *)
    echo "Invalid stage: $STAGE" >&2
    usage >&2
    exit 2
    ;;
esac

echo
printf 'Validation summary: %d passed, %d failed\n' "$PASSES" "$FAILURES"

if (( FAILURES > 0 )); then
  exit 1
fi