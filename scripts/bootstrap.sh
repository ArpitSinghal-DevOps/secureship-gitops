#!/usr/bin/env bash
# Creates a local minikube cluster, installs Argo CD and hands everything else to GitOps.
set -euo pipefail

PROFILE="${PROFILE:-secureship}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.2}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-5g}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for bin in minikube kubectl docker; do
  command -v "$bin" >/dev/null || { echo "missing: $bin (see README > Prerequisites)"; exit 1; }
done
if grep -rq "GITHUB_USER" "$ROOT_DIR/argocd" "$ROOT_DIR/policies" "$ROOT_DIR/chart"; then
  echo "GITHUB_USER placeholder still present. Run ../setup.sh <your-github-username> first."; exit 1
fi

echo "==> Starting minikube ($PROFILE). Calico is used because the default CNI ignores NetworkPolicy."
minikube start -p "$PROFILE" --driver=docker --cni=calico --cpus="$CPUS" --memory="$MEMORY"
kubectl config use-context "$PROFILE"

echo "==> Installing Argo CD $ARGOCD_VERSION"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Argo CD does not report child Application health by default, so sync waves in an
# app-of-apps would not wait. This health check makes Kyverno come up before the app.
kubectl -n argocd patch configmap argocd-cm --type merge -p "$(cat <<'EOF'
data:
  resource.customizations.health.argoproj.io_Application: |
    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil and obj.status.health ~= nil then
      hs.status = obj.status.health.status
      if obj.status.health.message ~= nil then
        hs.message = obj.status.health.message
      end
    end
    return hs
EOF
)"

kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s

echo "==> Applying the root app-of-apps"
kubectl apply -f "$ROOT_DIR/argocd/root.yaml"

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
cat <<EOF

Done. Argo CD is now syncing Kyverno, policies, monitoring and the app (takes ~5 minutes).

  Argo CD UI : kubectl -n argocd port-forward svc/argocd-server 8080:443   -> https://localhost:8080
               user: admin   password: $PASS
  Grafana    : kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80  -> http://localhost:3000
               user: admin   password: kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d
  App        : kubectl -n secureship port-forward svc/secureship 8081:80  -> http://localhost:8081
EOF
