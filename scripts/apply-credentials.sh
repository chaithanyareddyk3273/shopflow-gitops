#!/usr/bin/env bash
# Apply the passwords currently in Secret "shopflow-credentials" to the RUNNING Postgres
# and RabbitMQ of one environment, without deleting any data.
#
#   ./scripts/apply-credentials.sh shopflow-dev
#
# Why it's needed: Postgres and RabbitMQ only read POSTGRES_PASSWORD / RABBITMQ_DEFAULT_PASS
# when their data volume is first created. After the Secret changes (e.g. a new
# SealedSecret from seal-credentials.sh), the databases keep the old password until it's
# changed inside them. That's what this script does.
#
# The passwords travel from the Secret to the database through stdin: they're never
# printed, never written to a file, and never appear on a command line.
set -euo pipefail

NAMESPACE="${1:?usage: $0 <namespace, e.g. shopflow-dev>}"
K="kubectl -n $NAMESPACE"

secret_value() { $K get secret shopflow-credentials -o "jsonpath={.data.$1}" | base64 -d; }
PG_USER=$($K get statefulset postgres -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_USER")].value}')
MQ_USER=$($K get statefulset rabbitmq -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RABBITMQ_DEFAULT_USER")].value}')

echo "==> Postgres: setting the password for user '$PG_USER'"
# Connects through the local socket inside the pod, which needs no password
printf "ALTER USER \"%s\" WITH PASSWORD '%s';\n" "$PG_USER" "$(secret_value postgres-password)" \
  | $K exec -i postgres-0 -- psql -q -v ON_ERROR_STOP=1 -U "$PG_USER" -d shopflow

echo "==> RabbitMQ: setting the password for user '$MQ_USER'"
# With no password argument, rabbitmqctl reads it from stdin
secret_value rabbitmq-password | $K exec -i rabbitmq-0 -- rabbitmqctl change_password "$MQ_USER" >/dev/null

echo "==> Restarting the services so they reconnect with the new passwords"
for kind in deployment rollout; do
  for name in $($K get "$kind" -o name 2>/dev/null); do
    if [ "$kind" = rollout ]; then
      $K patch "$name" --type merge -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null
    else
      $K rollout restart "$name" >/dev/null
    fi
    echo "    restarted $name"
  done
done
echo "==> Done."
