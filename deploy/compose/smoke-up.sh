#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Prueba de levantamiento completo de la pila (US-08 / subtarea 3)
#
# 1. Valida estáticamente el compose del ambiente (validate-compose.sh).
# 2. dev: construye las 6 imágenes propias con el tag SemVer (sección build:).
#    stage/prod: descarga las imágenes publicadas en el registro (docker compose pull).
# 3. Levanta los 12 contenedores con `up --wait` (respeta depends_on: service_healthy).
# 4. Verifica que todos estén "healthy", que ninguna imagen en ejecución use :latest
#    y (dev) sondea desde el host los endpoints de salud publicados.
# 5. Desmonta la pila y sus volúmenes (salvo KEEP_UP=1).
#
# Uso:
#   bash deploy/compose/smoke-up.sh                       # dev, IMAGE_TAG=1.0.0
#   IMAGE_TAG=1.2.0 bash deploy/compose/smoke-up.sh dev
#   KEEP_UP=1 bash deploy/compose/smoke-up.sh             # deja la pila arriba
#   REGISTRY_URL=52.14.6.11:5000 IMAGE_TAG=1.2.0 PUBLIC_HOST=<ip> bash deploy/compose/smoke-up.sh stage
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_NAME="${1:-dev}"
IMAGE_TAG="${IMAGE_TAG:-${APP_VERSION:-1.0.0}}"
REGISTRY_URL="${REGISTRY_URL:-localhost:5000}"
PUBLIC_HOST="${PUBLIC_HOST:-localhost}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
KEEP_UP="${KEEP_UP:-0}"
COMPOSE_FILE="${ROOT_DIR}/deploy/compose/docker-compose.${ENV_NAME}.yml"
ENV_FILE="${ENV_FILE:-}"

log() { printf '\n[smoke-up][%s] %s\n' "${ENV_NAME}" "$*"; }

TMP_DIR="$(mktemp -d)"
if [[ -z "${ENV_FILE}" ]]; then
  ENV_FILE="${TMP_DIR}/.env.${ENV_NAME}"
  IMAGE_TAG="${IMAGE_TAG}" PUBLIC_HOST="${PUBLIC_HOST}" \
    bash "${ROOT_DIR}/infra/bootstrap/inject-jenkins-secrets.sh" \
      --env "${ENV_NAME}" --output "${ENV_FILE}" --registry-url "${REGISTRY_URL}" >/dev/null
fi

dc() { docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"; }

cleanup() {
  local rc=$?
  if [[ "${KEEP_UP}" != "1" ]]; then
    log "Desmontando la pila (down -v)..."
    dc down -v --remove-orphans >/dev/null 2>&1 || true
  else
    log "KEEP_UP=1: la pila sigue arriba. Archivo de entorno: ${ENV_FILE}"
  fi
  [[ "${KEEP_UP}" == "1" ]] || rm -rf "${TMP_DIR}"
  exit "${rc}"
}
trap cleanup EXIT

log "1/5 Validación estática (IMAGE_TAG=${IMAGE_TAG}, REGISTRY_URL=${REGISTRY_URL})"
IMAGE_TAG="${IMAGE_TAG}" REGISTRY_URL="${REGISTRY_URL}" bash "${ROOT_DIR}/deploy/compose/validate-compose.sh" "${ENV_NAME}"

if [[ "${ENV_NAME}" == "dev" ]]; then
  log "2/5 Construyendo las 6 imágenes propias con tag ${IMAGE_TAG}"
  DOCKER_BUILDKIT=1 dc build
else
  log "2/5 Descargando imágenes publicadas (${REGISTRY_URL}/circleguard/*:${IMAGE_TAG})"
  dc pull
fi

NET_NAME="$(grep -E '^DOCKER_NETWORK_NAME=' "${ENV_FILE}" | cut -d= -f2- || true)"
NET_NAME="${DOCKER_NETWORK_NAME:-${NET_NAME:-circleguard_${ENV_NAME}_net}}"
if ! docker network inspect "${NET_NAME}" >/dev/null 2>&1; then
  log "Creando red externa del ambiente '${NET_NAME}' (en los nodos la crea bootstrap-env.sh)"
  docker network create --driver bridge "${NET_NAME}" >/dev/null
fi

log "3/5 Levantando la pila (up --wait, timeout ${WAIT_TIMEOUT}s)"
start_ts=$(date +%s)
if ! dc up -d --wait --wait-timeout "${WAIT_TIMEOUT}"; then
  dc ps -a
  log "Contenedores no saludables — últimas líneas de log:"
  for c in $(dc ps -a --format '{{.Service}} {{.Health}}' | awk '$2!="healthy"{print $1}'); do
    echo "----- ${c}"; dc logs --tail 40 "${c}" || true
  done
  exit 1
fi
log "Pila saludable en $(( $(date +%s) - start_ts ))s"

log "4/5 Verificando estado de salud y tags de imágenes en ejecución"
dc ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
failures=0
expected=12
running=0
while read -r svc health image; do
  running=$((running + 1))
  [[ "${health}" == "healthy" ]] || { echo "   [FAIL] ${svc} no está healthy (${health})"; failures=$((failures + 1)); }
  if [[ "${image}" == *":latest" || "${image##*/}" != *:* ]]; then
    echo "   [FAIL] ${svc} ejecuta una imagen sin tag inmutable: ${image}"; failures=$((failures + 1))
  fi
done < <(dc ps --format '{{.Service}} {{.Health}} {{.Image}}')
[[ ${running} -eq ${expected} ]] || { echo "   [FAIL] se esperaban ${expected} contenedores, hay ${running}"; failures=$((failures + 1)); }

if [[ "${ENV_NAME}" == "dev" ]]; then
  # Sondeo funcional desde el host a través de los puertos publicados.
  probe() {
    local name="$1" url="$2"
    if curl -fsS --max-time 10 "${url}" >/dev/null; then
      echo "   [OK]   ${name}: ${url}"
    else
      echo "   [FAIL] ${name}: ${url}"; failures=$((failures + 1))
    fi
  }
  probe auth-service      "http://127.0.0.1:8180/actuator/health/readiness"
  probe identity-service  "http://127.0.0.1:8083/actuator/health/readiness"
  probe promotion-service "http://127.0.0.1:8088/actuator/health/readiness"
  probe form-service      "http://127.0.0.1:8086/actuator/health/readiness"
  probe gateway-service   "http://127.0.0.1:8087/actuator/health/readiness"
  probe web-client        "http://127.0.0.1:8080/healthz"
  probe web-runtime-cfg   "http://127.0.0.1:8080/runtime-config.js"
fi

log "5/5 Resultado"
if [[ ${failures} -eq 0 ]]; then
  echo "=== SMOKE OK — ${running}/${expected} contenedores healthy, imágenes SemVer ${IMAGE_TAG}, sin :latest ==="
else
  echo "=== SMOKE FALLÓ — ${failures} verificaciones fallaron ===" >&2
  exit 1
fi
