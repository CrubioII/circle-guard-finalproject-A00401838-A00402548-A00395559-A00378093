#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Despliegue del namespace y el middleware de un ambiente (US-21)
#
#   1. Valida y genera el overlay deploy/k8s/overlays/<env>.
#   2. Comprueba que el clúster es el del ambiente: sus nodos llevan la etiqueta
#      circleguard.io/environment=<env> que pone US-20. Así no se aplica prod en
#      el clúster de dev por error de contexto.
#   3. Aplica el namespace, las políticas y el middleware (kubectl apply).
#   4. Crea el Secret si se pasa --env-file; si no, exige que ya exista.
#   5. Espera a que los 6 StatefulSets estén listos y muestra pods y volúmenes.
#
# Uso:
#   export KUBECONFIG=~/.kube/circleguard-dev.yaml        # get-kubeconfig.sh
#   bash deploy/k8s/scripts/deploy-middleware.sh --env dev --env-file /tmp/cg-dev.env
# Opciones:
#   --context <ctx>          contexto de kubeconfig
#   --timeout <duración>     espera por StatefulSet (por defecto 600s)
#   --server-dry-run         valida contra la API sin cambiar nada
#   --allow-shared-cluster   omite el paso 2 (clúster local con los 3 namespaces)
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME=""
ENV_FILE=""
CONTEXT=""
TIMEOUT="600s"
SERVER_DRY_RUN=false
ALLOW_SHARED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="${2:?--env necesita un valor}"; shift ;;
        --env-file) ENV_FILE="${2:?--env-file necesita un valor}"; shift ;;
        --context) CONTEXT="${2:?--context necesita un valor}"; shift ;;
        --timeout) TIMEOUT="${2:?--timeout necesita un valor}"; shift ;;
        --server-dry-run) SERVER_DRY_RUN=true ;;
        --allow-shared-cluster) ALLOW_SHARED=true ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done
[[ -n "${ENV_NAME}" ]] || fail "Falta --env (dev, stage o prod)."
require_env "${ENV_NAME}"
NAMESPACE="$(namespace_for "${ENV_NAME}")"
SCRIPTS_DIR="$(dirname "${BASH_SOURCE[0]}")"
KUBECTL="$(ensure_tool kubectl)"
KCTL=("${KUBECTL}")
[[ -n "${CONTEXT}" ]] && KCTL+=(--context "${CONTEXT}")

# 1. Validar y generar.
bash "${SCRIPTS_DIR}/validate.sh" --env "${ENV_NAME}" --skip-schema
RENDERED="${ROOT_DIR}/reports/k8s/${ENV_NAME}.yaml"

# 2. Clúster correcto.
"${KCTL[@]}" get namespace default -o name --request-timeout=15s >/dev/null 2>&1 \
    || fail "No hay conexión con la API de Kubernetes. Revisa KUBECONFIG o --context."
if [[ "${ALLOW_SHARED}" != "true" ]]; then
    node_envs="$("${KCTL[@]}" get nodes -o jsonpath='{range .items[*]}{.metadata.labels.circleguard\.io/environment}{"\n"}{end}' | sort -u | tr '\n' ' ')"
    [[ "${node_envs}" == "${ENV_NAME} " ]] \
        || fail "Los nodos del clúster son de '${node_envs% }', no de ${ENV_NAME}. Usa el kubeconfig de ${ENV_NAME} o --allow-shared-cluster."
fi
ok "Clúster: $("${KCTL[@]}" config current-context 2>/dev/null || echo '<sin contexto>'), $("${KCTL[@]}" get nodes --no-headers | wc -l | tr -d ' ') nodo(s)."

# 3. Aplicar.
if [[ "${SERVER_DRY_RUN}" == "true" ]]; then
    "${KCTL[@]}" apply --dry-run=server -f "${RENDERED}"
    ok "Dry-run en el servidor correcto para ${NAMESPACE}; no se cambió nada."
    exit 0
fi
"${KCTL[@]}" apply -f "${RENDERED}"

# 4. Secret.
if [[ -n "${ENV_FILE}" ]]; then
    ctx_args=()
    [[ -n "${CONTEXT}" ]] && ctx_args=(--context "${CONTEXT}")
    bash "${SCRIPTS_DIR}/create-secrets.sh" --env "${ENV_NAME}" --env-file "${ENV_FILE}" ${ctx_args[@]+"${ctx_args[@]}"}
fi
"${KCTL[@]}" -n "${NAMESPACE}" get secret "${SECRET_NAME}" >/dev/null 2>&1 \
    || fail "Falta el Secret ${SECRET_NAME} en ${NAMESPACE}. Ejecuta create-secrets.sh o pasa --env-file."

# 5. Esperar.
for sts in "${MIDDLEWARE[@]}"; do
    log "Esperando statefulset/${sts}..."
    "${KCTL[@]}" -n "${NAMESPACE}" rollout status "statefulset/${sts}" --timeout "${TIMEOUT}" \
        || { "${KCTL[@]}" -n "${NAMESPACE}" describe pod -l "app.kubernetes.io/name=${sts}" | tail -n 30 >&2
             fail "statefulset/${sts} no quedó listo en ${TIMEOUT}."; }
done
"${KCTL[@]}" -n "${NAMESPACE}" get pods,pvc -o wide
ok "Middleware listo en ${NAMESPACE}: ${MIDDLEWARE[*]}."
