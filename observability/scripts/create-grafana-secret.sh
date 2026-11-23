#!/usr/bin/env bash
# Crea o actualiza el Secret grafana-admin (US-24 / SCRUM-93) sin dejar la
# contraseña en el repositorio ni en el historial del shell.
#   GRAFANA_ADMIN_PASSWORD=<contraseña> bash observability/scripts/create-grafana-secret.sh
set -euo pipefail

: "${GRAFANA_ADMIN_PASSWORD:?Defina GRAFANA_ADMIN_PASSWORD}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
NAMESPACE="circleguard-observability"

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
kubectl -n "${NAMESPACE}" create secret generic grafana-admin \
    --from-literal=admin-user="${GRAFANA_ADMIN_USER}" \
    --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "[US-24] Secret grafana-admin listo en ${NAMESPACE}."
