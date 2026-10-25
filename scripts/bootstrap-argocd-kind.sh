#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.11}"
REPO_URL="https://github.com/iamahmadpk/dakiya-devops-takehome.git"

for cmd in kubectl kind openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command not found: $cmd" >&2; exit 1; }
done

CONTEXT="$(kubectl config current-context)"
if [[ "$CONTEXT" != kind-* ]]; then
  echo "ERROR: current kubectl context is '$CONTEXT', not a kind context." >&2
  echo "Switch to the intended local kind cluster first (kubectl config use-context kind-<cluster>)." >&2
  exit 1
fi

kubectl cluster-info >/dev/null

# Keep any pre-existing staging credential unchanged: it may match an initialized PVC.
kubectl create namespace dakiya-staging --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl get secret dakiya-release-secret -n dakiya-staging >/dev/null 2>&1; then
  if [[ -z "${DAKIYA_STAGING_DB_PASSWORD:-}" ]]; then
    echo "ERROR: dakiya-staging/dakiya-release-secret is missing." >&2
    echo "Set DAKIYA_STAGING_DB_PASSWORD to the password for the existing staging database, then rerun." >&2
    exit 1
  fi
  kubectl create secret generic dakiya-release-secret -n dakiya-staging \
    --from-literal=POSTGRES_USER=dakiya \
    --from-literal=POSTGRES_PASSWORD="$DAKIYA_STAGING_DB_PASSWORD" \
    --from-literal=POSTGRES_DB=dakiya
fi

# Isolated credentials for the fresh production and partner databases. Never overwrite existing secrets.
for ns in dakiya-production dakiya-retail-partner; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if ! kubectl get secret dakiya-db-secret -n "$ns" >/dev/null 2>&1; then
    password="$(openssl rand -hex 32)"
    kubectl create secret generic dakiya-db-secret -n "$ns" \
      --from-literal=POSTGRES_USER=dakiya \
      --from-literal=POSTGRES_PASSWORD="$password" \
      --from-literal=POSTGRES_DB=dakiya >/dev/null
    unset password
  fi
done

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  echo "Installing Argo CD ${ARGOCD_VERSION}..."
  kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
fi
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
kubectl wait --for=condition=Available deployment/argocd-repo-server -n argocd --timeout=300s

# The Helm release name is intentionally stable across namespaces. Use a separate
# Argo CD tracking label so Argo does not overwrite the chart's selector label
# app.kubernetes.io/instance and accidentally break Deployment/Service selectors.
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"application.instanceLabelKey":"argocd.argoproj.io/instance"}}' >/dev/null
kubectl rollout restart deployment/argocd-server -n argocd >/dev/null
kubectl rollout restart statefulset/argocd-application-controller -n argocd >/dev/null
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s >/dev/null
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s >/dev/null

# Optional: configure read access if the GitHub repository is private. Token is never written to Git.
if [[ -n "${GITHUB_REPO_TOKEN:-}" ]]; then
  kubectl create secret generic dakiya-github-repo -n argocd \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-literal=username="${GITHUB_REPO_USERNAME:-x-access-token}" \
    --from-literal=password="$GITHUB_REPO_TOKEN" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | kubectl apply -f - >/dev/null
fi

kubectl apply -f "$ROOT_DIR/deploy/gitops/apps/"

echo
echo "Argo CD applications submitted. Initial sync can take several minutes while images and PVCs initialize."
kubectl get applications -n argocd
printf '\nTo open the Argo CD UI in another terminal:\n'
printf '  kubectl port-forward svc/argocd-server -n argocd 8080:443\n'
printf 'Then browse to https://localhost:8080\n'
printf 'Initial admin password (retrieve locally; do not share it):\n'
printf '  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo\n'
