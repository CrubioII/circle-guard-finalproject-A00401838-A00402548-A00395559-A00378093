#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Secret del middleware en Kubernetes (US-21)
#
# Crea o actualiza el Secret circleguard-middleware en circleguard-<env>. Las
# contraseñas no se guardan en Git ni pasan por la línea de comandos: se leen
# del .env que genera infra/bootstrap/inject-jenkins-secrets.sh (US-05) o de
# variables de entorno, y se envían a kubectl desde un archivo temporal 600.
#
# Uso:
#   bash infra/bootstrap/inject-jenkins-secrets.sh --env dev --output /tmp/cg-dev.env
#   bash deploy/k8s/scripts/create-secrets.sh --env dev --env-file /tmp/cg-dev.env
#   POSTGRES_PASSWORD=... NEO4J_PASSWORD=... REDIS_PASSWORD=... LDAP_ADMIN_PASSWORD=... \
#     bash deploy/k8s/scripts/create-secrets.sh --env dev
# Opciones: --context <contexto>, --dry-run (muestra las claves, nunca los valores).
#
# Claves: POSTGRES_USER, POSTGRES_PASSWORD, NEO4J_USER, NEO4J_PASSWORD,
# NEO4J_AUTH (usuario/clave), REDIS_PASSWORD y LDAP_ADMIN_PASSWORD.
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME=""
ENV_FILE=""
CONTEXT=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="${2:?--env necesita un valor}"; shift ;;
        --env-file) ENV_FILE="${2:?--env-file necesita un valor}"; shift ;;
        --context) CONTEXT="${2:?--context necesita un valor}"; shift ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done
[[ -n "${ENV_NAME}" ]] || fail "Falta --env (dev, stage o prod)."
require_env "${ENV_NAME}"
NAMESPACE="$(namespace_for "${ENV_NAME}")"
KUBECTL="$(ensure_tool kubectl)"
KCTL=("${KUBECTL}")
[[ -n "${CONTEXT}" ]] && KCTL+=(--context "${CONTEXT}")

# Lee KEY=valor del .env sin ejecutarlo (los valores pueden tener $ o comillas).
read_key() {
    local key="$1" value=""
    if [[ -n "${ENV_FILE}" ]]; then
        value="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- | tr -d '\r')" || true
    fi
    [[ -n "${value}" ]] || value="${!key:-}"
    printf '%s' "${value}"
}

if [[ -n "${ENV_FILE}" ]]; then
    [[ -f "${ENV_FILE}" ]] || fail "No existe ${ENV_FILE}."
fi

POSTGRES_USER_VAL="$(read_key POSTGRES_USER)"; POSTGRES_USER_VAL="${POSTGRES_USER_VAL:-cg_${ENV_NAME}_user}"
NEO4J_USER_VAL="$(read_key NEO4J_USER)"; NEO4J_USER_VAL="${NEO4J_USER_VAL:-neo4j}"
declare -A SECRETS=(
    [POSTGRES_PASSWORD]="$(read_key POSTGRES_PASSWORD)"
    [NEO4J_PASSWORD]="$(read_key NEO4J_PASSWORD)"
    [REDIS_PASSWORD]="$(read_key REDIS_PASSWORD)"
    [LDAP_ADMIN_PASSWORD]="$(read_key LDAP_ADMIN_PASSWORD)"
)
for key in "${!SECRETS[@]}"; do
    value="${SECRETS[${key}]}"
    [[ -n "${value}" ]] || fail "Falta ${key} (en --env-file o como variable de entorno)."
    [[ ${#value} -ge 8 ]] || fail "${key} debe tener al menos 8 caracteres."
    [[ "${value}" =~ ^(your_.*_here|changeme|password)$ ]] && fail "${key} tiene un valor de ejemplo; usa el generado por inject-jenkins-secrets.sh."
    [[ "${value}" != *$'\n'* ]] || fail "${key} no puede tener saltos de línea."
done
# Neo4j 5 exige al menos 8 caracteres en la clave inicial (validado arriba).

umask 077
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
{
    printf 'POSTGRES_USER=%s\n' "${POSTGRES_USER_VAL}"
    printf 'POSTGRES_PASSWORD=%s\n' "${SECRETS[POSTGRES_PASSWORD]}"
    printf 'NEO4J_USER=%s\n' "${NEO4J_USER_VAL}"
    printf 'NEO4J_PASSWORD=%s\n' "${SECRETS[NEO4J_PASSWORD]}"
    printf 'NEO4J_AUTH=%s/%s\n' "${NEO4J_USER_VAL}" "${SECRETS[NEO4J_PASSWORD]}"
    printf 'REDIS_PASSWORD=%s\n' "${SECRETS[REDIS_PASSWORD]}"
    printf 'LDAP_ADMIN_PASSWORD=%s\n' "${SECRETS[LDAP_ADMIN_PASSWORD]}"
} > "${TMP}"

if [[ "${DRY_RUN}" == "true" ]]; then
    ok "Secret ${SECRET_NAME} para ${NAMESPACE} con las claves: $(cut -d= -f1 "${TMP}" | tr '\n' ' ')(valores ocultos)."
    exit 0
fi

"${KCTL[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "No existe el namespace ${NAMESPACE}. Aplica antes el overlay (deploy-middleware.sh)."

"${KCTL[@]}" create secret generic "${SECRET_NAME}" --namespace "${NAMESPACE}" \
        --from-env-file="${TMP}" --dry-run=client -o yaml \
    | "${KCTL[@]}" label --local -f - -o yaml \
        app.kubernetes.io/part-of=circleguard "circleguard.io/environment=${ENV_NAME}" \
    | "${KCTL[@]}" apply -f - >/dev/null
ok "Secret ${SECRET_NAME} actualizado en ${NAMESPACE} (7 claves, valores ocultos)."
