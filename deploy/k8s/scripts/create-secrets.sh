#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Secrets del middleware y de los microservicios (US-21, US-37)
#
# Crea o actualiza los Secrets circleguard-middleware y circleguard-app en circleguard-<env>. Las
# contraseñas no se guardan en Git ni pasan por la línea de comandos: se leen
# del .env que genera infra/bootstrap/inject-jenkins-secrets.sh (US-05) o de
# variables de entorno, y se envían a kubectl desde un archivo temporal 600.
#
# Uso:
#   bash infra/bootstrap/inject-jenkins-secrets.sh --env dev --output /tmp/cg-dev.env
#   bash deploy/k8s/scripts/create-secrets.sh --env dev --env-file /tmp/cg-dev.env
#   POSTGRES_PASSWORD=... NEO4J_PASSWORD=... REDIS_PASSWORD=... LDAP_ADMIN_PASSWORD=... \
#   JWT_SECRET=... QR_SECRET=... VAULT_SECRET=... VAULT_SALT=... VAULT_HASH_SALT=... \
#     bash deploy/k8s/scripts/create-secrets.sh --env dev
# Opciones: --context <contexto>, --dry-run (muestra las claves, nunca los valores).
#   --generate    genera un valor aleatorio para cada clave que no venga en el .env ni en
#                 el entorno (P3: ambiente nuevo sin .env). Nadie necesita conocer esos
#                 valores: los servicios los leen del Secret.
#   --if-missing  no toca un Secret que ya existe (no cambia claves de un ambiente vivo).
#   Ambiente nuevo: bash deploy/k8s/scripts/create-secrets.sh --env stage --generate --if-missing
# Lo corre un administrador del clúster: la cuenta jenkins-deployer no puede leer ni
# escribir Secrets (US-26), así que el pipeline solo avisa si faltan (k8s-deploy.sh verify).
#
# circleguard-middleware: POSTGRES_USER, POSTGRES_PASSWORD, NEO4J_USER, NEO4J_PASSWORD,
# NEO4J_AUTH (usuario/clave), REDIS_PASSWORD y LDAP_ADMIN_PASSWORD.
# circleguard-app (US-37): JWT_SECRET, QR_SECRET, VAULT_SECRET, VAULT_SALT y VAULT_HASH_SALT.
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME=""
ENV_FILE=""
CONTEXT=""
DRY_RUN=false
GENERATE=false
IF_MISSING=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="${2:?--env necesita un valor}"; shift ;;
        --env-file) ENV_FILE="${2:?--env-file necesita un valor}"; shift ;;
        --context) CONTEXT="${2:?--context necesita un valor}"; shift ;;
        --dry-run) DRY_RUN=true ;;
        --generate) GENERATE=true ;;
        --if-missing) IF_MISSING=true ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
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
APP_KEYS=(JWT_SECRET QR_SECRET VAULT_SECRET VAULT_SALT VAULT_HASH_SALT)
for key in "${APP_KEYS[@]}"; do SECRETS[${key}]="$(read_key "${key}")"; done
if [[ "${GENERATE}" == "true" ]]; then
    for key in "${!SECRETS[@]}"; do
        # 32 caracteres alfanuméricos: sirven en URLs JDBC, en NEO4J_AUTH y en LDAP.
        [[ -n "${SECRETS[${key}]}" ]] || SECRETS[${key}]="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)"
    done
fi
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
TMP_APP="$(mktemp)"
trap 'rm -f "${TMP}" "${TMP_APP}"' EXIT
{
    printf 'POSTGRES_USER=%s\n' "${POSTGRES_USER_VAL}"
    printf 'POSTGRES_PASSWORD=%s\n' "${SECRETS[POSTGRES_PASSWORD]}"
    printf 'NEO4J_USER=%s\n' "${NEO4J_USER_VAL}"
    printf 'NEO4J_PASSWORD=%s\n' "${SECRETS[NEO4J_PASSWORD]}"
    printf 'NEO4J_AUTH=%s/%s\n' "${NEO4J_USER_VAL}" "${SECRETS[NEO4J_PASSWORD]}"
    printf 'REDIS_PASSWORD=%s\n' "${SECRETS[REDIS_PASSWORD]}"
    printf 'LDAP_ADMIN_PASSWORD=%s\n' "${SECRETS[LDAP_ADMIN_PASSWORD]}"
} > "${TMP}"
for key in "${APP_KEYS[@]}"; do printf '%s=%s\n' "${key}" "${SECRETS[${key}]}"; done > "${TMP_APP}"

if [[ "${DRY_RUN}" == "true" ]]; then
    ok "Secret ${SECRET_NAME} para ${NAMESPACE} con las claves: $(cut -d= -f1 "${TMP}" | tr '\n' ' ')(valores ocultos)."
    ok "Secret ${APP_SECRET_NAME} para ${NAMESPACE} con las claves: ${APP_KEYS[*]} (valores ocultos)."
    exit 0
fi

"${KCTL[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "No existe el namespace ${NAMESPACE}. Aplica antes el overlay (deploy-middleware.sh)."

secret_exists() { "${KCTL[@]}" -n "${NAMESPACE}" get secret "$1" >/dev/null 2>&1; }

apply_secret() {   # apply_secret <nombre> <archivo .env>
    "${KCTL[@]}" create secret generic "$1" --namespace "${NAMESPACE}" \
            --from-env-file="$2" --dry-run=client -o yaml \
        | "${KCTL[@]}" label --local -f - -o yaml \
            app.kubernetes.io/part-of=circleguard "circleguard.io/environment=${ENV_NAME}" \
        | "${KCTL[@]}" apply -f - >/dev/null
    ok "Secret $1 actualizado en ${NAMESPACE} ($(wc -l < "$2" | tr -d ' ') claves, valores ocultos)."
}
for pair in "${SECRET_NAME}:${TMP}" "${APP_SECRET_NAME}:${TMP_APP}"; do
    name="${pair%%:*}"
    if [[ "${IF_MISSING}" == "true" ]] && secret_exists "${name}"; then
        ok "Secret ${name} ya existe en ${NAMESPACE}; no se modifica (--if-missing)."
        continue
    fi
    apply_secret "${name}" "${pair#*:}"
done
