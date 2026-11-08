#!/usr/bin/env bash
# =============================================================================
# Suite de verificación de idempotencia y criterios de aceptación (US-04 / SCRUM-16 / SCRUM-42)
# Valida CA1, CA2 y CA3 mediante pruebas estáticas, estructurales y de ejecución repetida.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap-ci.sh"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.ci.yml"
JENKINS_DOCKERFILE="${SCRIPT_DIR}/jenkins/Dockerfile"
JENKINS_PLUGINS="${SCRIPT_DIR}/jenkins/plugins.txt"

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

printf '================================================================================\n'
printf ' Verificación de US-04 (SCRUM-16): bootstrap-ci.sh y docker-compose.ci.yml\n'
printf '================================================================================\n\n'

# -----------------------------------------------------------------------------
# 1. Validación CA1: Banderas de seguridad y sintaxis Bash
# -----------------------------------------------------------------------------
printf '[1/4] Validando CA1 (existencia, permisos, sintaxis y set -euo pipefail)...\n'
assert_true "Existe infra/bootstrap/bootstrap-ci.sh" test -f "$BOOTSTRAP_SCRIPT"
assert_true "infra/bootstrap/bootstrap-ci.sh tiene permisos de ejecución" test -x "$BOOTSTRAP_SCRIPT"
assert_true "Sintaxis Bash válida (bash -n)" bash -n "$BOOTSTRAP_SCRIPT"
assert_file_contains "Declara set -euo pipefail" "$BOOTSTRAP_SCRIPT" '^set -euo pipefail'

# -----------------------------------------------------------------------------
# 2. Validación CA2: Kernel vm.max_map_count=262144, Docker/Compose y Dockerfile Jenkins
# -----------------------------------------------------------------------------
printf '\n[2/4] Validando CA2 (vm.max_map_count=262144, Docker/Compose, Jenkins Dockerfile)...\n'
assert_file_contains "Configura vm.max_map_count=262144 para SonarQube" "$BOOTSTRAP_SCRIPT" 'REQUIRED_MAX_MAP_COUNT:-262144'
assert_file_contains "Verifica e instala Docker y Docker Compose v2" "$BOOTSTRAP_SCRIPT" 'docker compose version'
assert_true "Existe infra/bootstrap/jenkins/Dockerfile" test -f "$JENKINS_DOCKERFILE"
assert_true "Existe infra/bootstrap/jenkins/plugins.txt" test -f "$JENKINS_PLUGINS"
assert_file_contains "Dockerfile de Jenkins usa base JDK 21 con versión fija" "$JENKINS_DOCKERFILE" '^FROM jenkins/jenkins:2\.580\.2-jdk21'
assert_file_contains "Dockerfile de Jenkins instala Docker CLI y Compose plugin" "$JENKINS_DOCKERFILE" 'docker-ce-cli'
assert_file_contains "Dockerfile de Jenkins instala Node.js 20 LTS" "$JENKINS_DOCKERFILE" 'nodesource\.com'
assert_file_contains "Dockerfile de Jenkins instala dependencias de Playwright" "$JENKINS_DOCKERFILE" 'libnss3'
assert_file_contains "Dockerfile de Jenkins instala Gradle 8.5" "$JENKINS_DOCKERFILE" 'ARG GRADLE_VERSION=8\.5'
assert_file_contains "Dockerfile de Jenkins corre con usuario no-root (USER jenkins)" "$JENKINS_DOCKERFILE" '^USER jenkins'
assert_file_contains "Dockerfile de Jenkins define HEALTHCHECK" "$JENKINS_DOCKERFILE" '^HEALTHCHECK '

# -----------------------------------------------------------------------------
# 3. Validación CA3: Volúmenes persistentes, healthchecks y etiquetas sin :latest
# -----------------------------------------------------------------------------
printf '\n[3/4] Validando CA3 (docker-compose.ci.yml, volúmenes persistentes y healthchecks)...\n'
assert_true "Existe docker-compose.ci.yml en la raíz" test -f "$COMPOSE_FILE"
assert_file_contains "Define servicio jenkins" "$COMPOSE_FILE" '^  jenkins:'
assert_file_contains "Define servicio sonarqube-db" "$COMPOSE_FILE" '^  sonarqube-db:'
assert_file_contains "Define servicio sonarqube" "$COMPOSE_FILE" '^  sonarqube:'
assert_file_contains "Define servicio nexus" "$COMPOSE_FILE" '^  nexus:'
assert_file_contains "Monta socket de Docker en Jenkins" "$COMPOSE_FILE" '/var/run/docker\.sock:/var/run/docker\.sock'
assert_file_contains "Declara volumen persistente jenkins_home" "$COMPOSE_FILE" 'circleguard_jenkins_home'
assert_file_contains "Declara volumen persistente sonarqube_data" "$COMPOSE_FILE" 'circleguard_sonarqube_data'
assert_file_contains "Declara volumen persistente nexus_data" "$COMPOSE_FILE" 'circleguard_nexus_data'

HEALTHCHECK_COUNT="$(grep -c '^    healthcheck:' "$COMPOSE_FILE" || true)"
assert_true "Los 4 contenedores declaran bloque healthcheck activo (${HEALTHCHECK_COUNT}/4)" test "$HEALTHCHECK_COUNT" -eq 4

LATEST_COUNT="$(grep -Ec 'image:.*:latest' "$COMPOSE_FILE" || true)"
assert_true "Ninguna imagen en docker-compose.ci.yml usa el tag mutable :latest" test "$LATEST_COUNT" -eq 0

# -----------------------------------------------------------------------------
# 4. Prueba de idempotencia (SCRUM-42): Ejecución repetida (Run #1 vs Run #2)
# -----------------------------------------------------------------------------
printf '\n[4/4] Ejecutando prueba de idempotencia (Ejecución #1 y Ejecución #2 consecutivas)...\n'
TMP_STATE="$(mktemp -d)"
trap 'rm -rf "$TMP_STATE"' EXIT

RUN1_LOG="${TMP_STATE}/run1.log"
RUN2_LOG="${TMP_STATE}/run2.log"

bash "$BOOTSTRAP_SCRIPT" --dry-run --state-dir "$TMP_STATE" --public-host "10.0.10.25" > "$RUN1_LOG" 2>&1
assert_true "Ejecución #1 finaliza con código 0" test -f "${TMP_STATE}/.env.ci"
assert_file_contains "Ejecución #1 inicializa .env.ci con CI_PUBLIC_HOST=10.0.10.25" "${TMP_STATE}/.env.ci" '^CI_PUBLIC_HOST=10\.0\.10\.25$'

# Inyectar un valor personalizado en .env.ci para comprobar que la 2da ejecución no lo sobrescribe
printf 'CUSTOM_IDEMPOTENCY_TOKEN=preserve_across_runs\n' >> "${TMP_STATE}/.env.ci"

bash "$BOOTSTRAP_SCRIPT" --dry-run --state-dir "$TMP_STATE" --public-host "10.0.10.99" > "$RUN2_LOG" 2>&1
assert_file_contains "Ejecución #2 detecta sysctl ya actualizado sin reescribirlo" "$RUN2_LOG" 'Archivo sysctl .* ya está actualizado'
assert_file_contains "Ejecución #2 detecta limits ya actualizado sin reescribirlo" "$RUN2_LOG" 'Archivo limits .* ya está actualizado'
assert_file_contains "Ejecución #2 detecta swap ya registrado sin duplicar entrada" "$RUN2_LOG" 'Swap ya registrado'
assert_file_contains "Ejecución #2 conserva .env.ci existente sin sobrescribirlo" "$RUN2_LOG" 'ya existe; se conserva sin sobrescribir'
assert_file_contains "Ejecución #2 preserva tokens personalizados dentro de .env.ci" "${TMP_STATE}/.env.ci" '^CUSTOM_IDEMPOTENCY_TOKEN=preserve_across_runs$'

SYSCTL_LINES="$(grep -c '^vm\.max_map_count' "${TMP_STATE}/etc/sysctl.d/99-circleguard-ci.conf")"
FSTAB_LINES="$(grep -c '^/swapfile ' "${TMP_STATE}/etc/fstab")"
assert_true "Sin líneas duplicadas en 99-circleguard-ci.conf tras 2 ejecuciones (${SYSCTL_LINES} línea)" test "$SYSCTL_LINES" -eq 1
assert_true "Sin líneas duplicadas en /etc/fstab tras 2 ejecuciones (${FSTAB_LINES} línea)" test "$FSTAB_LINES" -eq 1

# Probar modos individuales (jenkins, sonarqube, nexus) y rechazo de modo inválido
for mode in jenkins sonarqube nexus; do
    bash "$BOOTSTRAP_SCRIPT" --dry-run --state-dir "$TMP_STATE" --mode "$mode" >/dev/null 2>&1
    assert_true "Soporta modo selectivo --mode ${mode}" true
done

if bash "$BOOTSTRAP_SCRIPT" --dry-run --mode modo_invalido >/dev/null 2>&1; then
    printf '  [FAIL] Debe rechazar un --mode inválido\n' >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    printf '  [PASS] Rechaza correctamente un --mode inválido con código != 0\n'
    PASS_COUNT=$((PASS_COUNT + 1))
fi

printf '\n================================================================================\n'
printf ' Resultado: %d pruebas exitosas, %d fallidas\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '================================================================================\n'

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
