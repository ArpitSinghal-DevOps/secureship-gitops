#!/usr/bin/env bash
# Starts the local cluster, installs Argo CD and hands everything else to GitOps.
# Needs only Docker on the laptop: kubectl runs inside the minikube node container
# (tools/k) and the minikube CLI runs in the toolbox container (tools/minikube).
set -euo pipefail

PROFILE="${PROFILE:-secureship}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.2}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-5g}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
K="$ROOT_DIR/tools/k"
export NODE="$PROFILE"

command -v docker >/dev/null || { echo "missing: docker"; exit 1; }
if grep -rq "GITHUB_USER" "$ROOT_DIR/argocd" "$ROOT_DIR/policies" "$ROOT_DIR/chart"; then
  echo "GITHUB_USER placeholder still present. Run ../setup.sh <your-github-username> first."; exit 1
fi

if docker inspect "$PROFILE" >/dev/null 2>&1; then
  echo "==> Cluster container '$PROFILE' exists, starting it"
  docker start "$PROFILE" >/dev/null
else
  echo "==> Creating minikube cluster '$PROFILE' (Calico, so NetworkPolicy is enforced)"
  "$ROOT_DIR/tools/minikube" start -p "$PROFILE" --driver=docker --cni=calico \
    --cpus="$CPUS" --memory="$MEMORY"
fi

echo "==> Waiting for the Kubernetes API"
for _ in $(seq 1 60); do "$K" --request-timeout=5s get --raw /readyz >/dev/null 2>&1 && break; sleep 5; done

echo "==> Installing Argo CD $ARGOCD_VERSION"
"$K" create namespace argocd --dry-run=client -o yaml | "$K" apply -f -
"$K" apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null

# Argo CD does not report child Application health by default, so sync waves in an
# app-of-apps would not wait. This health check makes Kyverno come up before the app.
"$K" -n argocd patch configmap argocd-cm --type merge -p "$(cat <<'EOF'
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

"$K" -n argocd rollout status deployment/argocd-server --timeout=300s
"$K" -n argocd rollout status deployment/argocd-repo-server --timeout=300s

echo "==> Applying the root app-of-apps"
"$K" apply -f - < "$ROOT_DIR/argocd/root.yaml"

PASS=$("$K" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PROFILE")
cat <<EOF

Done. Argo CD is syncing Kyverno, the policies and the app (takes ~5 minutes).
Run these from the secureship-gitops folder:

  Argo CD UI : tools/k -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443
               open https://$IP:8080   user: admin   password: $PASS
  App        : tools/k -n secureship port-forward --address 0.0.0.0 svc/secureship 8081:80
               open http://$IP:8081
  Stop/start : docker stop $PROFILE   /   ./scripts/bootstrap.sh
EOF
