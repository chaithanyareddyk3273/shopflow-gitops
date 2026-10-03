#!/usr/bin/env bash
# Create new random database/RabbitMQ passwords for one environment, encrypt them with
# the cluster's Sealed Secrets public key, and print the block to paste into
# environments/<env>/values.yaml.
#
#   ./scripts/seal-credentials.sh shopflow-dev
#
# The plain passwords are never printed or written to disk. Only the cluster's
# sealed-secrets controller can decrypt the output, and only into this namespace.
#
# ⚠️ Postgres and RabbitMQ only read their password when their data volume is created.
# For an environment that's already running, run ./scripts/apply-credentials.sh <namespace>
# after ArgoCD has synced (see the walkthrough, section 10.4).
set -euo pipefail

NAMESPACE="${1:?usage: $0 <namespace, e.g. shopflow-dev>}"

for tool in kubectl kubeseal python; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

# 32 random URL-safe characters each (safe inside a connection string)
gen() { python -c "import secrets; print(secrets.token_urlsafe(24))"; }

kubectl create secret generic shopflow-credentials \
    --namespace "$NAMESPACE" \
    --from-literal=postgres-password="$(gen)" \
    --from-literal=rabbitmq-password="$(gen)" \
    --dry-run=client -o json \
  | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o json \
  | python -c '
import json, sys
data = json.load(sys.stdin)["spec"]["encryptedData"]
print("sealedSecrets:")
print("  enabled: true")
print("  encryptedData:")
for key in ("postgres-password", "rabbitmq-password"):
    print(f"    {key}: {data[key]}")
'
