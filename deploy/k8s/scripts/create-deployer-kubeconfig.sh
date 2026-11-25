#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Kubeconfig de Jenkins con permisos de un solo namespace (US-26)
#
# Lo corre un administrador del clúster, una vez por ambiente y cada vez que quiera
# rotar el token. Con el kubeconfig de administrador (get-kubeconfig.sh):
#   1. Aplica el RBAC del overlay (ServiceAccounts, Role y RoleBinding de circleguard-<env>).
#   2. Crea el Secret jenkins-deployer-token, el token de larga duración de la cuenta
#      jenkins-deployer. Con --rotate lo borra antes: el token anterior deja de valer.
#   3. Escribe un kubeconfig (600) con ese token, la CA del clúster y el namespace del
#      ambiente, y comprueba con "kubectl auth can-i" que despliega pero no lee Secrets
#      ni sale del namespace.
# El archivo se sube a Jenkins como credencial de tipo archivo 'kubeconfig-<env>' y
# después se borra del equipo. Nunca se versiona.
#
# Uso:
#   export KUBECONFIG=~/.kube/circleguard-dev.yaml      # administrador (get-kubeconfig.sh)
#   bash deploy/k8s/scripts/create-deployer-kubeconfig.sh --env dev
#   bash deploy/k8s/scripts/create-deployer-kubeconfig.sh --env dev --rotate
# Opciones: --context <contexto>, --output <archivo> (por defecto
# ~/.kube/jenkins-deployer-<env>.yaml), --server <URL de la API> (si Jenkins la ve
# con otra dirección que el administrador).
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SA_NAME="jenkins-deployer"
TOKEN_SECRET="${SA_NAME}-token"
ENV_NAME=""
CONTEXT=""
OUTPUT=""
SERVER=""
ROTATE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="${2:?--env necesita un valor}"; shift ;;
        --context) CONTEXT="${2:?--context necesita un valor}"; shift ;;
        --output) OUTPUT="${2:?--output necesita un valor}"; shift ;;
        --server) SERVER="${2:?--server necesita un valor}"; shift ;;
        --rotate) ROTATE=true ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done
[[ -n "${ENV_NAME}" ]] || fail "Falta --env (dev, stage o prod)."
require_env "${ENV_NAME}"
NAMESPACE="$(namespace_for "${ENV_NAME}")"
OUTPUT="${OUTPUT:-${HOME}/.kube/jenkins-deployer-${ENV_NAME}.yaml}"
KUBECTL="$(ensure_tool kubectl)"
YQ="$(ensure_tool yq)"
KCTL=("${KUBECTL}")
[[ -n "${CONTEXT}" ]] && KCTL+=(--context "${CONTEXT}")

"${KCTL[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "No existe el namespace ${NAMESPACE}. Aplica antes el overlay (deploy-middleware.sh)."

# --- 1. RBAC del namespace ---------------------------------------------------
"${KUBECTL}" kustomize "${K8S_DIR}/overlays/${ENV_NAME}" \
    | "${YQ}" e 'select(.kind == "ServiceAccount" or .kind == "Role" or .kind == "RoleBinding")' - \
    | "${KCTL[@]}" apply -f - >/dev/null
ok "RBAC de ${NAMESPACE} aplicado (cuentas de servicio y Role ${SA_NAME})."

# --- 2. Token de la cuenta ---------------------------------------------------
if [[ "${ROTATE}" == "true" ]]; then
    "${KCTL[@]}" -n "${NAMESPACE}" delete secret "${TOKEN_SECRET}" --ignore-not-found >/dev/null
    log "Token anterior de ${SA_NAME} revocado."
fi
"${KCTL[@]}" -n "${NAMESPACE}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${TOKEN_SECRET}
  labels: {app.kubernetes.io/part-of: circleguard, circleguard.io/environment: ${ENV_NAME}}
  annotations: {kubernetes.io/service-account.name: ${SA_NAME}}
type: kubernetes.io/service-account-token
EOF

TOKEN=""
for _ in $(seq 1 20); do
    TOKEN="$("${KCTL[@]}" -n "${NAMESPACE}" get secret "${TOKEN_SECRET}" -o jsonpath='{.data.token}' 2>/dev/null || true)"
    [[ -n "${TOKEN}" ]] && break
    sleep 1
done
[[ -n "${TOKEN}" ]] || fail "Kubernetes no generó el token de ${TOKEN_SECRET}."
CA_DATA="$("${KCTL[@]}" -n "${NAMESPACE}" get secret "${TOKEN_SECRET}" -o jsonpath='{.data.ca\.crt}')"
[[ -n "${SERVER}" ]] || SERVER="$("${KCTL[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "${SERVER}" == https://* ]] || fail "La API debe usar https (encontrado: ${SERVER})."

# --- 3. Kubeconfig -----------------------------------------------------------
umask 077
mkdir -p "$(dirname "${OUTPUT}")"
TMP="$(mktemp "$(dirname "${OUTPUT}")/.deployer.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT
CTX="${SA_NAME}@${NAMESPACE}"
cat > "${TMP}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: circleguard-${ENV_NAME}
    cluster: {server: ${SERVER}, certificate-authority-data: ${CA_DATA}}
users:
  - name: ${SA_NAME}
    user: {token: $(printf '%s' "${TOKEN}" | base64 --decode)}
contexts:
  - name: ${CTX}
    context: {cluster: circleguard-${ENV_NAME}, user: ${SA_NAME}, namespace: ${NAMESPACE}}
current-context: ${CTX}
EOF

# Comprobación: lo que k8s-deploy.sh necesita, sí; lo demás, no.
can() { KUBECONFIG="${TMP}" "${KUBECTL}" auth can-i "$@" 2>/dev/null || true; }
expect() {   # expect <yes|no> <verbo> <recurso> [-n namespace]
    local want="$1"; shift
    local got; got="$(can "$@")"
    [[ "${got}" == "${want}" ]] || fail "El token de ${SA_NAME} responde '${got}' a 'can-i $*' (se esperaba ${want})."
}
expect yes patch deployments.apps
expect yes create configmaps
expect yes patch namespaces/"${NAMESPACE}"
expect no get secrets
expect no create pods/exec
expect no get pods -n kube-system
for other in "${ALL_ENVS[@]}"; do
    [[ "${other}" == "${ENV_NAME}" ]] || expect no patch deployments.apps -n "$(namespace_for "${other}")"
done
mv "${TMP}" "${OUTPUT}"
chmod 600 "${OUTPUT}"
ok "Kubeconfig de ${SA_NAME} en ${OUTPUT} (solo ${NAMESPACE}, sin acceso a Secrets)."
log "Súbelo a Jenkins como credencial de archivo 'kubeconfig-${ENV_NAME}' y bórralo de este equipo."
