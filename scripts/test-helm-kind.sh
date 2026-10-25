
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/deploy/helm/dakiya"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-dakiya-cluster}"
NAMESPACE="${K8S_NAMESPACE:-dakiya-staging}"
RELEASE="${HELM_RELEASE:-dakiya-release}"
API_IMAGE="dakiya-api:local"
WORKER_IMAGE="dakiya-worker:local"
EXISTING_SECRET="${POSTGRES_EXISTING_SECRET:-dakiya-release-secret}"
RENDERED_FILE="$(mktemp)"

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$RENDERED_FILE"
}
trap cleanup EXIT

for cmd in docker kind kubectl helm curl python3; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: $cmd is required" >&2
    exit 1
  }
done

docker info >/dev/null

# Create the Kind cluster if it does not exist.
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "Creating Kind cluster: $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME"
fi

kubectl --context "kind-$CLUSTER_NAME" cluster-info

# Use the selected Kind cluster for subsequent kubectl commands.
kubectl config use-context "kind-$CLUSTER_NAME"

# Build and load local application images.
docker build -t "$API_IMAGE" -f "$ROOT/api/Dockerfile" "$ROOT/api"
docker build -t "$WORKER_IMAGE" -f "$ROOT/worker/Dockerfile" "$ROOT/worker"

kind load docker-image "$API_IMAGE" "$WORKER_IMAGE" --name "$CLUSTER_NAME"

# Validate the Helm chart.
helm lint "$CHART"

# Create the namespace if necessary.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml |
  kubectl apply -f -

# The externally managed Secret must exist before Helm installation.
if ! kubectl get secret "$EXISTING_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: Secret '$EXISTING_SECRET' does not exist in namespace '$NAMESPACE'." >&2
  echo "Create it with POSTGRES_USER, POSTGRES_PASSWORD and POSTGRES_DB first." >&2
  exit 1
fi

# Verify required Secret keys without printing their values.
kubectl get secret "$EXISTING_SECRET" -n "$NAMESPACE" -o json |
  python3 -c '
import json, sys
secret = json.load(sys.stdin)
required = {"POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"}
present = set(secret.get("data", {}))
missing = required - present
if missing:
    print("ERROR: Missing Secret keys:", ", ".join(sorted(missing)), file=sys.stderr)
    sys.exit(1)
print("Existing PostgreSQL Secret has all required keys.")
'

# Render using the same settings as the actual installation.
helm template "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --set image.api.repository=dakiya-api \
  --set image.api.tag=local \
  --set image.worker.repository=dakiya-worker \
  --set image.worker.tag=local \
  --set image.pullPolicy=IfNotPresent \
  --set-string postgresql.existingSecret="$EXISTING_SECRET" \
  > "$RENDERED_FILE"

# Ensure the chart doesn't render its own PostgreSQL Secret when an
# externally managed Secret is configured.
if grep -Eq 'kind: Secret' "$RENDERED_FILE"; then
  echo "ERROR: Helm rendered a Secret despite postgresql.existingSecret being set." >&2
  echo "Check the conditional in templates/secret.yaml." >&2
  exit 1
fi

# Install or upgrade the release.
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --set image.api.repository=dakiya-api \
  --set image.api.tag=local \
  --set image.worker.repository=dakiya-worker \
  --set image.worker.tag=local \
  --set image.pullPolicy=IfNotPresent \
  --set-string postgresql.existingSecret="$EXISTING_SECRET" \
  --wait \
  --timeout 5m

kubectl get pods,svc,pvc -n "$NAMESPACE" -o wide

kubectl rollout status "deployment/$RELEASE-api" \
  -n "$NAMESPACE" --timeout=180s

kubectl rollout status "deployment/$RELEASE-worker" \
  -n "$NAMESPACE" --timeout=180s

# Smoke test through a temporary port-forward.
PORT="${LOCAL_API_PORT:-18000}"
PF_PID=""

kubectl port-forward -n "$NAMESPACE" "svc/$RELEASE-api" "$PORT:8000" \
  >/tmp/dakiya-port-forward.log 2>&1 &
PF_PID=$!

READY=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null; then
    READY=1
    break
  fi
  sleep 2
done

if [[ "$READY" -ne 1 ]]; then
  echo "ERROR: API health check failed. Port-forward logs:" >&2
  cat /tmp/dakiya-port-forward.log >&2 || true
  kubectl logs -n "$NAMESPACE" "deployment/$RELEASE-api" --tail=100 >&2 || true
  exit 1
fi

echo "Health:"
curl -fsS "http://127.0.0.1:$PORT/health"
echo

echo "Readiness:"
curl -fsS "http://127.0.0.1:$PORT/readiness"
echo

echo "Submitting test scan:"
curl -fsS -X POST "http://127.0.0.1:$PORT/scans" \
  -H 'Content-Type: application/json' \
  -d '{"tracking_id":"KIND-TEST-001","status":"booked","depot":"kind-test","scanned_at":"2026-10-26T12:00:00Z"}'
echo

sleep 3

echo "Checking test parcel:"
curl -fsS "http://127.0.0.1:$PORT/parcels/KIND-TEST-001"
echo

echo "PASS: Helm chart installed on Kind and API smoke tests completed."
