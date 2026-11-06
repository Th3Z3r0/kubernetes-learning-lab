#!/usr/bin/env bash
# Single entry point for checking and safely recovering the Kubernetes learning lab.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-lab.sh"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-lab.sh"
MODE="check"
STAGE="all"
SMOKE=true
CONFIRM_DELETE=false
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kubernetes-learning-lab"
LOG_FILE=""

usage() {
  cat <<'USAGE'
Usage: bash 00-prerequisites/scripts/lab-manager.sh [check|recover|recreate] [options]

Modes:
  check       Validate the current lab; do not change the cluster (default)
  recover     Check first; on failure, run non-destructive bootstrap then revalidate
  recreate    Destroy/rebuild kind intentionally; requires --confirm-delete

Options:
  --stage NAME       Check only: tools, kind-bootstrap, cilium, storage,
                     namespace, all (default)
  --no-smoke          Skip active Service/Ingress/PVC smoke tests
  --confirm-delete    Required for recreate; existing kind objects/data are lost
  -h, --help          Show help

Normal usage (from repository root):
  bash 00-prerequisites/scripts/lab-manager.sh check
  bash 00-prerequisites/scripts/lab-manager.sh recover

This wrapper never automatically deletes an existing kind cluster in recover mode.
The script does not run git pull while executing; update the repo separately.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    check|recover|recreate) MODE="$1"; shift ;;
    --stage)
      [[ $# -ge 2 ]] || { echo "[ERROR] --stage needs an argument" >&2; exit 2; }
      STAGE="$2"; shift 2 ;;
    --no-smoke) SMOKE=false; shift ;;
    --confirm-delete) CONFIRM_DELETE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$STAGE" in
  tools|kind-bootstrap|cilium|storage|namespace|all) ;;
  *) echo "[ERROR] Invalid stage: $STAGE" >&2; exit 2 ;;
esac

if [[ "$MODE" != "check" && "$STAGE" != "all" ]]; then
  echo "[ERROR] --stage is only supported in check mode" >&2
  exit 2
fi
if [[ "$MODE" == "recreate" && "$CONFIRM_DELETE" != "true" ]]; then
  echo "[ERROR] Recreate destroys the existing kind cluster and its local data." >&2
  echo "[ERROR] Pass --confirm-delete only if you intend to erase the cluster." >&2
  exit 2
fi
[[ -f "$VALIDATOR" && -f "$BOOTSTRAP" ]] || {
  echo "[ERROR] Bootstrap/validator scripts are missing from $SCRIPT_DIR" >&2
  exit 2
}

mkdir -p "$STATE_DIR" || exit 1
LOG_FILE="$STATE_DIR/lab-manager-$(date +%Y%m%d-%H%M%S)-$$.log"
echo "[INFO] Mode: $MODE; stage: $STAGE; smoke: $SMOKE"
echo "[INFO] Log: $LOG_FILE"

run_logged() {
  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

diagnostics() {
  echo "[INFO] Collecting read-only diagnostics" | tee -a "$LOG_FILE"
  {
    if command -v kind >/dev/null 2>&1; then
      echo "=== kind clusters ==="
      kind get clusters 2>&1 || true
    fi
    if command -v docker >/dev/null 2>&1; then
      echo "=== kind Docker containers ==="
      docker ps -a --filter "name=kind" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1 || true
      echo "=== kind control-plane IP ==="
      docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER_NAME:-kind}-control-plane" 2>&1 || true
    fi
    if command -v kubectl >/dev/null 2>&1; then
      echo "=== Kubernetes nodes ==="
      kubectl get nodes -o wide --request-timeout=10s 2>&1 || true
      echo "=== Kubernetes Pods ==="
      kubectl get pods -A -o wide --request-timeout=10s 2>&1 || true
      echo "=== recent Kubernetes events ==="
      kubectl get events -A --sort-by=.lastTimestamp --request-timeout=10s 2>&1 | tail -n 40 || true
    fi
    if command -v helm >/dev/null 2>&1; then
      echo "=== configured Cilium API endpoint ==="
      helm get values cilium -n kube-system -o json 2>&1 \
        | (command -v jq >/dev/null 2>&1 && jq '{k8sServiceHost,k8sServicePort}' || cat) || true
    fi
  } | tee -a "$LOG_FILE"
}

check() {
  local args=(--stage "$STAGE")
  if "$SMOKE"; then args+=(--smoke); fi
  run_logged bash "$VALIDATOR" "${args[@]}"
}

final_result() {
  local rc="$1"
  if (( rc == 0 )); then
    echo "[PASS] Lab ready. Validation succeeded. Log: $LOG_FILE"
  else
    echo "[FAIL] Lab still unhealthy. Review diagnostics and log: $LOG_FILE" >&2
  fi
  return "$rc"
}

case "$MODE" in
  check)
    if check; then
      final_result 0
    else
      diagnostics
      final_result 1
    fi
    ;;
  recover)
    if check; then
      echo "[INFO] Lab is already healthy; no bootstrap or changes required."
      final_result 0
      exit 0
    fi
    diagnostics
    echo "[INFO] Running safe bootstrap to reuse and repair the existing cluster."
    if ! run_logged bash "$BOOTSTRAP"; then
      echo "[FAIL] Safe bootstrap failed. Existing kind cluster was not intentionally deleted." >&2
      diagnostics
      final_result 1
      exit 1
    fi
    if check; then final_result 0; else diagnostics; final_result 1; fi
    ;;
  recreate)
    echo "[WARN] Destructive recreate explicitly requested." | tee -a "$LOG_FILE"
    if ! run_logged bash "$BOOTSTRAP" --recreate-cluster; then
      diagnostics
      final_result 1
      exit 1
    fi
    if check; then final_result 0; else diagnostics; final_result 1; fi
    ;;
esac
