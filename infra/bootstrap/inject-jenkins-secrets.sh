#!/usr/bin/env bash
# =============================================================================
# Inyector idempotente de secretos desde Jenkins Credentials Store (US-05 / CA2 / SCRUM-44)
#
# Propósito:
#   Genera o actualiza de forma segura el archivo .env de un ambiente aislado
#   (dev, stage o prod) inyectando secretos provenientes de withCredentials(...)
#   en Jenkins sin exponer contraseñas en el repositorio Git.
#
# Uso desde Jenkinsfile / SSH:
#   POSTGRES_PASSWORD="$CG_PG_PASS" NEO4J_PASSWORD="$CG_NEO4J_PASS" \
#   REDIS_PASSWORD="$CG_REDIS_PASS" LDAP_ADMIN_PASSWORD="$CG_LDAP_PASS" \
#   JWT_SECRET="$CG_JWT_SECRET" QR_SECRET="$CG_QR_SECRET" VAULT_SECRET="$CG_VAULT_SECRET" \
#   bash infra/bootstrap/inject-jenkins-secrets.sh --env dev --output /opt/circleguard/dev/.env
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_ENV=""
OUTPUT_FILE=""
REGISTRY_URL="${REGISTRY_URL:-52.14.6.11:5000}"
APP_VERSION="${APP_VERSION:-0.1.0}"
FORCE_ROTATE="${FORCE_ROTATE:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            TARGET_ENV="${2:?Falta valor para --env (dev|stage|prod)}"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="${2:?Falta valor para --output}"
            shift 2
            ;;
        --registry-url)
            REGISTRY_URL="${2:?Falta valor para --registry-url}"
            shift 2
            ;;
        --app-version)
            APP_VERSION="${2:?Falta valor para --app-version}"
            shift 2
            ;;
        --force-rotate)
            FORCE_ROTATE="true"
            shift
            ;;
        *)
            printf '[inject-secrets][ERROR] Opción desconocida: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

case "$TARGET_ENV" in
    dev|stage|prod) ;;
    *)
        printf '[inject-secrets][ERROR] Ambiente inválido "%s". Valores permitidos: dev, stage, prod.\n' "$TARGET_ENV" >&2
        exit 1
        ;;
esac

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="/opt/circleguard/${TARGET_ENV}/.env"
fi

# Si el archivo ya existe y no se pidió rotación ni se pasaron secretos nuevos explícitos,
# conservar los secretos existentes para garantizar idempotencia.
read_existing_key() {
    local key="$1"
    if [[ -f "$OUTPUT_FILE" ]] && [[ "$FORCE_ROTATE" != "true" ]]; then
        grep -E "^${key}=" "$OUTPUT_FILE" 2>/dev/null | head -n 1 | cut -d= -f2- || true
    fi
}

generate_secret_hex() {
    local bytes="${1:-24}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
    else
        head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

resolve_secret() {
    local env_var_name="$1"
    local bytes="${2:-24}"
    local explicit_val="${!env_var_name:-}"
    if [[ -n "$explicit_val" ]] && [[ "$explicit_val" != \<* ]]; then
        printf '%s' "$explicit_val"
        return 0
    fi
    local existing_val
    existing_val="$(read_existing_key "$env_var_name")"
    if [[ -n "$existing_val" ]] && [[ "$existing_val" != \<* ]]; then
        printf '%s' "$existing_val"
        return 0
    fi
    generate_secret_hex "$bytes"
}

mkdir -p "$(dirname "$OUTPUT_FILE")"

PG_PASS="$(resolve_secret POSTGRES_PASSWORD 16)"
NEO4J_PASS="$(resolve_secret NEO4J_PASSWORD 16)"
REDIS_PASS="$(resolve_secret REDIS_PASSWORD 16)"
LDAP_PASS="$(resolve_secret LDAP_ADMIN_PASSWORD 16)"
JWT_SEC="$(resolve_secret JWT_SECRET 32)"
QR_SEC="$(resolve_secret QR_SECRET 24)"
VAULT_SEC="$(resolve_secret VAULT_SECRET 32)"
VAULT_SALT_VAL="$(resolve_secret VAULT_SALT 8)"
VAULT_HASH_VAL="$(resolve_secret VAULT_HASH_SALT 8)"

TMP_ENV="${OUTPUT_FILE}.tmp.$$"
umask 077
cat > "$TMP_ENV" <<EOF
# Generado de forma idempotente por infra/bootstrap/inject-jenkins-secrets.sh (US-05)
# Ambiente aislado: ${TARGET_ENV}
TARGET_ENV=${TARGET_ENV}
SPRING_PROFILES_ACTIVE=${TARGET_ENV}
APP_VERSION=${APP_VERSION}
REGISTRY_URL=${REGISTRY_URL}
REGISTRY_INSECURE=true
DOCKER_NETWORK_NAME=circleguard_${TARGET_ENV}_net

# Credenciales de middleware externalizadas (inyectadas desde Jenkins / generadas con permisos 0600)
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=circleguard_${TARGET_ENV}
POSTGRES_USER=cg_${TARGET_ENV}_user
POSTGRES_PASSWORD=${PG_PASS}

NEO4J_HTTP_PORT=7474
NEO4J_BOLT_PORT=7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=${NEO4J_PASS}

ZOOKEEPER_PORT=2181
KAFKA_PORT=9092
KAFKA_ADVERTISED_HOST=kafka

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASS}

LDAP_PORT=389
LDAPS_PORT=636
LDAP_ORGANISATION=CircleGuard-${TARGET_ENV}
LDAP_DOMAIN=${TARGET_ENV}.circleguard.edu
LDAP_ADMIN_PASSWORD=${LDAP_PASS}

# Secretos criptográficos de microservicios
JWT_SECRET=${JWT_SEC}
QR_SECRET=${QR_SEC}
VAULT_SECRET=${VAULT_SEC}
VAULT_SALT=${VAULT_SALT_VAL}
VAULT_HASH_SALT=${VAULT_HASH_VAL}
EOF

chmod 600 "$TMP_ENV"
mv "$TMP_ENV" "$OUTPUT_FILE"
printf '[inject-secrets][OK] Archivo de secretos reconciliado con permisos 0600 en %s (ambiente=%s)\n' "$OUTPUT_FILE" "$TARGET_ENV"
