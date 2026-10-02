#!/usr/bin/env bash
# Install ArgoCD into the local kind cluster and hand it the app-of-apps.
# After this, ArgoCD deploys shopflow-dev and shopflow-prod from this Git repo by itself.
# Run from the shopflow-gitops folder (Git Bash on Windows):   ./scripts/argocd-up.sh
set -euo pipefail

CLUSTER=shopflow

for tool in kind kubectl; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

if ! kind get clusters | grep -qx "$CLUSTER"; then
  echo "==> Creating kind cluster '$CLUSTER'"
  kind create cluster --config kind/kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> Installing ArgoCD (stable release)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# --server-side: ArgoCD's CRDs are too large for a normal (client-side) apply
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null
kubectl rollout status -n argocd deployment/argocd-server --timeout=5m
kubectl rollout status -n argocd statefulset/argocd-application-controller --timeout=5m

echo "==> Handing ArgoCD the app-of-apps (it creates shopflow-dev and shopflow-prod)"
kubectl apply -f argocd/root.yaml

cat <<'EOF'

==> ArgoCD is running.
    Open the UI:   kubectl port-forward -n argocd svc/argocd-server 8443:443
                   then https://localhost:8443  (accept the self-signed certificate)
    Username:      admin
    Password:      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

    Watch the apps: kubectl get applications -n argocd -w
EOF
