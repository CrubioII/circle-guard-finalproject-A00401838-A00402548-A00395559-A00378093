#!/usr/bin/env bash
# =============================================================================
# Suite de verificación de idempotencia y externalización de secretos (US-05 / SCRUM-17)
# Valida CA1, CA2 y CA3 para los ambientes aislados dev, stage y prod.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_ENV="${SCRIPT_DIR}/bootstrap-env.sh"
INJECT_SECRETS="${SCRIPT_DIR}/inject-jenkins-secrets.sh"
COMPOSE_DEV="${REPO_ROOT}/docker-compose.dev.yml"
ROOT_ENV_EXAMPLE="${REPO_ROOT}/.env.example"

PASS_COUNT=0
FAIL_COUNT=0

assert_true() {
    local description="$1"
    shift
    if "$@"; then
        printf '  [PASS] %s\n' "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  [FAIL] %s\n' "$description" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_file_contains() {
    local description="$1"
    local file="$2"
    local pattern="$3"
    if grep -Eq "$pattern" "$file"; then
        printf '  [PASS] %s\n' "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  [FAIL] %s (patrón no encontrado: %s en %s)\n' "$description" "$pattern" "$file" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_file_not_contains() {
    local description="$1"
    local file="$2"
    local pattern="$3"
    if ! grep -Eq "$pattern" "$file"; then
        printf '  [PASS] %s\n' "$description"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  [FAIL] %s (patrón prohibido encontrado: %s en %s)\n' "$description" "$pattern" "$file" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

printf '================================================================================\n'
printf ' Verificación de US-05 (SCRUM-17): bootstrap-env.sh y externalización de secretos\n'
printf '================================================================================\n\n'

# -----------------------------------------------------------------------------
# 1. Validación CA1: Script bootstrap-env.sh parametrizado por ambiente
# -----------------------------------------------------------------------------
printf '[1/4] Validando CA1 (bootstrap-env.sh, set -euo pipefail, soporte dev/stage/prod)...\n'
assert_true "Existe infra/bootstrap/bootstrap-env.sh" test -f "$BOOTSTRAP_ENV"
assert_true "infra/bootstrap/bootstrap-env.sh tiene permisos de ejecución" test -x "$BOOTSTRAP_ENV"
assert_true "Sintaxis Bash válida en bootstrap-env.sh" bash -n "$BOOTSTRAP_ENV"
assert_true "Sintaxis Bash válida en inject-jenkins-secrets.sh" bash -n "$INJECT_SECRETS"
assert_file_contains "Declara set -euo pipefail en bootstrap-env.sh" "$BOOTSTRAP_ENV" '^set -euo pipefail'
assert_file_contains "Configura registro en /etc/docker/daemon.json" "$BOOTSTRAP_ENV" 'insecure-registries'
assert_file_contains "Soporta docker login hacia el registro de imágenes" "$BOOTSTRAP_ENV" 'login "\$REGISTRY_URL"'

# -----------------------------------------------------------------------------
# 2. Validación CA2: Eliminación de secretos en texto plano y .env.example
# -----------------------------------------------------------------------------
printf '\n[2/4] Validando CA2 (sin credenciales en texto plano en docker-compose.dev.yml y .env.example)...\n'
assert_true "Existe .env.example en la raíz del repositorio" test -f "$ROOT_ENV_EXAMPLE"
assert_true "Existe infra/bootstrap/env/.env.dev.example" test -f "${SCRIPT_DIR}/env/.env.dev.example"
assert_true "Existe infra/bootstrap/env/.env.stage.example" test -f "${SCRIPT_DIR}/env/.env.stage.example"
assert_true "Existe infra/bootstrap/env/.env.prod.example" test -f "${SCRIPT_DIR}/env/.env.prod.example"

assert_file_not_contains "Sin POSTGRES_PASSWORD: password en docker-compose.dev.yml" "$COMPOSE_DEV" 'POSTGRES_PASSWORD:[[:space:]]*password'
assert_file_not_contains "Sin NEO4J_AUTH: neo4j/password en docker-compose.dev.yml" "$COMPOSE_DEV" 'NEO4J_AUTH:[[:space:]]*neo4j/password'
assert_file_not_contains "Sin LDAP_ADMIN_PASSWORD: \"admin\" en docker-compose.dev.yml" "$COMPOSE_DEV" 'LDAP_ADMIN_PASSWORD:[[:space:]]*"?admin"?'
assert_file_contains "POSTGRES_PASSWORD parametrizado en docker-compose.dev.yml" "$COMPOSE_DEV" '\$\{POSTGRES_PASSWORD:\?'
assert_file_contains "NEO4J_PASSWORD parametrizado en docker-compose.dev.yml" "$COMPOSE_DEV" '\$\{NEO4J_PASSWORD:\?'
assert_file_contains "REDIS_PASSWORD parametrizado en docker-compose.dev.yml" "$COMPOSE_DEV" '\$\{REDIS_PASSWORD:\?'
assert_file_contains "LDAP_ADMIN_PASSWORD parametrizado en docker-compose.dev.yml" "$COMPOSE_DEV" '\$\{LDAP_ADMIN_PASSWORD:\?'

# -----------------------------------------------------------------------------
# 3. Validación CA3 e Idempotencia: Ejecución repetida para dev, stage y prod
# -----------------------------------------------------------------------------
printf '\n[3/4] Validando CA3 e idempotencia en los 3 ambientes (dev, stage, prod)...\n'
TMP_STATE="$(mktemp -d)"
trap 'rm -rf "$TMP_STATE"' EXIT

for env_name in dev stage prod; do
    RUN1="${TMP_STATE}/run1_${env_name}.log"
    RUN2="${TMP_STATE}/run2_${env_name}.log"

    bash "$BOOTSTRAP_ENV" "$env_name" --state-dir "$TMP_STATE" --registry-url "18.117.90.15:5000" > "$RUN1" 2>&1
    ENV_PATH="${TMP_STATE}/opt/circleguard/${env_name}/.env"
    assert_true "[${env_name}] Ejecución #1 crea directorio aislado y archivo .env" test -f "$ENV_PATH"
    assert_file_contains "[${env_name}] Define red aislada circleguard_${env_name}_net" "$ENV_PATH" "^DOCKER_NETWORK_NAME=circleguard_${env_name}_net$"
    assert_file_contains "[${env_name}] Define base de datos aislada circleguard_${env_name}" "$ENV_PATH" "^POSTGRES_DB=circleguard_${env_name}$"

    FIRST_PG_PASS="$(grep '^POSTGRES_PASSWORD=' "$ENV_PATH" | cut -d= -f2)"

    bash "$BOOTSTRAP_ENV" "$env_name" --state-dir "$TMP_STATE" --registry-url "18.117.90.15:5000" > "$RUN2" 2>&1
    SECOND_PG_PASS="$(grep '^POSTGRES_PASSWORD=' "$ENV_PATH" | cut -d= -f2)"

    assert_file_contains "[${env_name}] Ejecución #2 detecta sysctl ya actualizado" "$RUN2" 'Archivo sysctl .* ya actualizado'
    assert_true "[${env_name}] Ejecución #2 preserva secretos generados sin sobrescribirlos" test "$FIRST_PG_PASS" = "$SECOND_PG_PASS"
done

# Verificar aislamiento entre secretos generados para dev, stage y prod
DEV_JWT="$(grep '^JWT_SECRET=' "${TMP_STATE}/opt/circleguard/dev/.env" | cut -d= -f2)"
STAGE_JWT="$(grep '^JWT_SECRET=' "${TMP_STATE}/opt/circleguard/stage/.env" | cut -d= -f2)"
PROD_JWT="$(grep '^JWT_SECRET=' "${TMP_STATE}/opt/circleguard/prod/.env" | cut -d= -f2)"
assert_true "Secretos JWT son únicos y aislados entre dev y stage" test "$DEV_JWT" != "$STAGE_JWT"
assert_true "Secretos JWT son únicos y aislados entre stage y prod" test "$STAGE_JWT" != "$PROD_JWT"

# -----------------------------------------------------------------------------
# 4. Validación de inyección de secretos desde Jenkins y rechazo de ambiente inválido
# -----------------------------------------------------------------------------
printf '\n[4/4] Validando inyección explícita desde Jenkins Credentials Store...\n'
POSTGRES_PASSWORD="jenkins_injected_pg_secret_99" \
JWT_SECRET="jenkins_injected_jwt_secret_32_chars_min_001" \
bash "$INJECT_SECRETS" --env prod --output "${TMP_STATE}/opt/circleguard/prod/.env" >/dev/null

assert_file_contains "Inyección desde Jenkins actualiza POSTGRES_PASSWORD en prod/.env" \
    "${TMP_STATE}/opt/circleguard/prod/.env" '^POSTGRES_PASSWORD=jenkins_injected_pg_secret_99$'
assert_file_contains "Inyección desde Jenkins actualiza JWT_SECRET en prod/.env" \
    "${TMP_STATE}/opt/circleguard/prod/.env" '^JWT_SECRET=jenkins_injected_jwt_secret_32_chars_min_001$'

if bash "$BOOTSTRAP_ENV" invalido --dry-run >/dev/null 2>&1; then
    printf '  [FAIL] Debe rechazar un ambiente inválido\n' >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    printf '  [PASS] Rechaza correctamente un ambiente inválido con código != 0\n'
    PASS_COUNT=$((PASS_COUNT + 1))
fi

printf '\n================================================================================\n'
printf ' Resultado: %d pruebas exitosas, %d fallidas\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '================================================================================\n'

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
