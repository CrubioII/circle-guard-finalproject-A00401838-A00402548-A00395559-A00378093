#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Despliegue idempotente de una versión SemVer en un ambiente (US-13)
#
# Se ejecuta EN el nodo del ambiente (Jenkins lo copia y lo invoca por SSH con
# deploy/scripts/environment.sh) o en local para pruebas. Pasos:
#   1. Valida ambiente, IMAGE_TAG SemVer y archivos (.env de US-05, compose de US-08).
#   2. docker login al registro (contraseña SOLO por stdin, nunca en argumentos).
#   3. Crea la red externa del ambiente si falta.
#   4. config -q -> pull -> up -d --wait (respeta depends_on: service_healthy).
#   5. Persiste IMAGE_TAG en el .env y registra DEPLOYED_VERSION (versión anterior incluida).
# Si `up --wait` falla, imprime el estado y los logs de los contenedores no sanos y sale != 0.
#
# Uso:
#   IMAGE_TAG=1.4.0 bash deploy-env.sh dev
#   printf '%s' "$PASS" | REGISTRY_USER=u REGISTRY_PASSWORD_STDIN=1 IMAGE_TAG=1.4.0 bash deploy-env.sh stage
# Variables opcionales: DEPLOY_BASE_DIR (/opt/circleguard), ENV_FILE, COMPOSE_FILE, STATE_FILE,
#   REGISTRY_URL (por defecto el del .env), SKIP_PULL=1, WAIT_TIMEOUT (900 s).
# =============================================================================
set -euo pipefail

ENV_NAME="${1:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
DEPLOY_BASE_DIR="${DEPLOY_BASE_DIR:-/opt/circleguard}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
SKIP_PULL="${SKIP_PULL:-0}"
REGISTRY_PASSWORD_STDIN="${REGISTRY_PASSWORD_STDIN:-0}"
SEMVER_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

log() { printf '[deploy-env][%s] %s\n' "${ENV_NAME:-?}" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

case "${ENV_NAME}" in
  dev|stage|prod) ;;
  *) die "ambiente inválido '${ENV_NAME}' (dev|stage|prod)" ;;
esac
[[ "${IMAGE_TAG}" =~ ${SEMVER_REGEX} ]] || die "IMAGE_TAG '${IMAGE_TAG}' no cumple SemVer (nunca 'latest')"

BASE_DIR="${DEPLOY_BASE_DIR}/${ENV_NAME}"
ENV_FILE="${ENV_FILE:-${BASE_DIR}/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${BASE_DIR}/compose/stack/docker-compose.${ENV_NAME}.yml}"
STATE_FILE="${STATE_FILE:-$(dirname "${ENV_FILE}")/DEPLOYED_VERSION}"

[[ -f "${ENV_FILE}" ]] || die "no existe ${ENV_FILE} (ejecute infra/bootstrap/bootstrap-env.sh ${ENV_NAME})"
[[ -f "${COMPOSE_FILE}" ]] || die "no existe ${COMPOSE_FILE}"
command -v docker >/dev/null 2>&1 || die "docker no está instalado"
docker compose version >/dev/null 2>&1 || die "docker compose v2 no está disponible"

env_value() { grep -E "^$1=" "${ENV_FILE}" 2>/dev/null | tail -n 1 | cut -d= -f2- || true; }

REGISTRY_URL="${REGISTRY_URL:-$(env_value REGISTRY_URL)}"
NET_NAME="${DOCKER_NETWORK_NAME:-$(env_value DOCKER_NETWORK_NAME)}"
NET_NAME="${NET_NAME:-circleguard_${ENV_NAME}_net}"
PREVIOUS_TAG="$(grep -E '^IMAGE_TAG=' "${STATE_FILE}" 2>/dev/null | cut -d= -f2- || true)"
PREVIOUS_TAG="${PREVIOUS_TAG:-$(env_value IMAGE_TAG)}"

# La variable de shell tiene prioridad sobre --env-file en compose: fija la versión desplegada.
export IMAGE_TAG
[[ -n "${REGISTRY_URL}" ]] && export REGISTRY_URL
dc() { docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"; }

log "Versión a desplegar: ${IMAGE_TAG} (anterior: ${PREVIOUS_TAG:-ninguna}) | registro: ${REGISTRY_URL:-<del .env>}"

# 1. Autenticación en el registro (Nexus). La contraseña llega por stdin.
if [[ "${REGISTRY_PASSWORD_STDIN}" == "1" ]]; then
  [[ -n "${REGISTRY_USER:-}" ]] || die "REGISTRY_PASSWORD_STDIN=1 requiere REGISTRY_USER"
  [[ -n "${REGISTRY_URL}" ]] || die "REGISTRY_URL no definido"
  docker login "${REGISTRY_URL}" -u "${REGISTRY_USER}" --password-stdin >/dev/null
  log "Sesión iniciada en ${REGISTRY_URL} como ${REGISTRY_USER}"
fi

# 2. Red externa del ambiente (la crea bootstrap-env.sh; se reconcilia aquí de forma idempotente).
if ! docker network inspect "${NET_NAME}" >/dev/null 2>&1; then
  docker network create --driver bridge "${NET_NAME}" >/dev/null
  log "Red '${NET_NAME}' creada"
fi

# 3. Render, pull y arranque con espera de healthchecks.
dc config -q
if [[ "${SKIP_PULL}" != "1" ]]; then
  log "Descargando imágenes ${REGISTRY_URL}/circleguard/*:${IMAGE_TAG}"
  dc pull --quiet
fi

log "Aplicando la pila (up -d --wait, timeout ${WAIT_TIMEOUT}s)"
start_ts=$(date +%s)
if ! dc up -d --remove-orphans --wait --wait-timeout "${WAIT_TIMEOUT}"; then
  log "La pila no quedó saludable con ${IMAGE_TAG}. Estado actual:"
  dc ps -a >&2 || true
  for svc in $(dc ps -a --format '{{.Service}} {{.Health}}' | awk '$2!="healthy"{print $1}'); do
    printf -- '----- logs: %s\n' "${svc}" >&2
    dc logs --tail 60 "${svc}" >&2 || true
  done
  exit 1
fi
elapsed=$(( $(date +%s) - start_ts ))

# 4. Persistencia: un reinicio manual o del host conserva la versión desplegada.
if grep -qE '^IMAGE_TAG=' "${ENV_FILE}"; then
  sed -i.bak "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
else
  printf '\nIMAGE_TAG=%s\n' "${IMAGE_TAG}" >>"${ENV_FILE}"
fi
umask 027
cat >"${STATE_FILE}" <<EOF
ENV=${ENV_NAME}
IMAGE_TAG=${IMAGE_TAG}
PREVIOUS_IMAGE_TAG=${PREVIOUS_TAG}
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ELAPSED_SECONDS=${elapsed}
EOF

log "DEPLOY_OK env=${ENV_NAME} tag=${IMAGE_TAG} previous=${PREVIOUS_TAG:-none} elapsed=${elapsed}s"
