#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Rollback a la última versión estable de un ambiente (US-14 / CA2)
# Historia de Usuario: US-14 (SCRUM-26)
#
# Mantiene, por ambiente, un registro de versiones SemVer desplegadas y la última
# versión estable (la que pasó el smoke test / healthcheck post-despliegue), y
# redespliega los contenedores con esa versión cuando un despliegue falla o cuando
# se solicita explícitamente desde Jenkins (parámetro ROLLBACK_TARGET_VERSION).
#
# Comandos:
#   rollback.sh mark-deployed <env> <version>   Registra <version> como desplegada (antes del smoke test)
#   rollback.sh mark-stable <env> <version>     Registra <version> como estable en <env>
#   rollback.sh rollback    <env> [--to X.Y.Z] [--host IP]
#                                               Restaura --to o, si se omite, la última estable
#   rollback.sh status      <env>               Muestra versión actual, estable e historial
#
# Ejecución del redespliegue:
#   --host IP  Nodo remoto del ambiente: reutiliza deploy/scripts/environment.sh
#              (deploy + verify por SSH, US-13) con la versión a restaurar.
#   sin --host docker compose local con deploy/compose/docker-compose.<env>.yml (US-08).
#
# Variables:
#   ENV_FILE           .env del ambiente en modo local (por defecto lo genera inject-jenkins-secrets.sh)
#   REGISTRY_URL       Registro Docker (Nexus) con las imágenes SemVer
#   ROLLBACK_STATE_DIR Estado de versiones (por defecto $JENKINS_HOME/circleguard-releases,
#                      persistente en el volumen de Jenkins, o /var/lib/circleguard/releases)
#   ENVIRONMENT_SCRIPT Orquestador remoto (por defecto deploy/scripts/environment.sh)
#   WAIT_TIMEOUT       Segundos máximos para que la pila quede healthy (por defecto 600)
#   DRY_RUN=1          Muestra los comandos sin ejecutarlos
#
# Códigos de salida: 0 éxito | 1 error de uso | 2 sin versión estable | 3 la pila
# restaurada no quedó saludable.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_STATE="/var/lib/circleguard/releases"
[[ -n "${JENKINS_HOME:-}" ]] && DEFAULT_STATE="${JENKINS_HOME}/circleguard-releases"
STATE_ROOT="${ROLLBACK_STATE_DIR:-${DEFAULT_STATE}}"
ENVIRONMENT_SCRIPT="${ENVIRONMENT_SCRIPT:-${ROOT_DIR}/deploy/scripts/environment.sh}"
HOST=""
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
DRY_RUN="${DRY_RUN:-0}"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'

log()  { printf '[rollback][%s] %s\n' "${ENV_NAME:-?}" "$*"; }
fail() { printf '[rollback][%s][ERROR] %s\n' "${ENV_NAME:-?}" "$*" >&2; exit "${2:-1}"; }

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

validate_env() {
  case "$1" in dev|stage|prod) ;; *) fail "Ambiente inválido '$1' (dev|stage|prod)." ;; esac
}

validate_version() {
  [[ "$1" != "latest" ]] || fail "Nunca se despliega el tag mutable 'latest'."
  [[ "$1" =~ $SEMVER_RE ]] || fail "Versión '$1' no cumple SemVer (X.Y.Z o X.Y.Z-rc.N)."
}

state_dir()   { printf '%s/%s' "${STATE_ROOT}" "${ENV_NAME}"; }
read_state()  { local f; f="$(state_dir)/$1"; [[ -s "$f" ]] && tr -d '[:space:]' < "$f" || true; }
write_state() { mkdir -p "$(state_dir)"; printf '%s\n' "$2" > "$(state_dir)/$1"; }
history_add() {
  mkdir -p "$(state_dir)"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${BUILD_URL:-manual}" >> "$(state_dir)/history.tsv"
}

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

prepare_env_file() {
  COMPOSE_FILE="${ROOT_DIR}/deploy/compose/docker-compose.${ENV_NAME}.yml"
  [[ -f "${COMPOSE_FILE}" ]] || fail "No existe ${COMPOSE_FILE}."
  if [[ -z "${ENV_FILE:-}" ]]; then
    ENV_FILE="$(mktemp)"
    trap 'rm -f "${ENV_FILE}"' EXIT
    REGISTRY_URL="${REGISTRY_URL:-18.117.90.15:5000}" \
      bash "${ROOT_DIR}/infra/bootstrap/inject-jenkins-secrets.sh" \
        --env "${ENV_NAME}" --output "${ENV_FILE}" --registry-url "${REGISTRY_URL:-18.117.90.15:5000}" >/dev/null
  fi
  [[ -f "${ENV_FILE}" ]] || fail "No existe el archivo de entorno ${ENV_FILE}."
}

# IMAGE_TAG del entorno del proceso tiene prioridad sobre --env-file al interpolar.
dc() { IMAGE_TAG="${TARGET_VERSION}" docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"; }

cmd_mark_deployed() {
  validate_version "$1"
  write_state current_version "$1"
  history_add "deployed" "$1"
  log "Versión desplegada registrada: $1 (última estable: $(read_state last_stable_version || true))."
}

cmd_mark_stable() {
  local version="$1"
  validate_version "${version}"
  local previous; previous="$(read_state last_stable_version)"
  write_state current_version "${version}"
  write_state last_stable_version "${version}"
  if [[ -n "${previous}" && "${previous}" != "${version}" ]]; then
    write_state previous_stable_version "${previous}"
  fi
  history_add "stable" "${version}"
  log "Versión estable registrada: ${version} (anterior: ${previous:-ninguna})."
}

# Redespliegue en el nodo remoto reutilizando el orquestador de US-13.
redeploy_remote() {
  [[ -x "${ENVIRONMENT_SCRIPT}" || -f "${ENVIRONMENT_SCRIPT}" ]] \
    || fail "No existe ${ENVIRONMENT_SCRIPT} (despliegue de US-13)."
  local dry=(); [[ "${DRY_RUN}" == "1" ]] && dry=(--dry-run)
  log "Redesplegando ${TARGET_VERSION} en ${HOST} con ${ENVIRONMENT_SCRIPT##*/}"
  if ! bash "${ENVIRONMENT_SCRIPT}" deploy --env "${ENV_NAME}" --version "${TARGET_VERSION}" --host "${HOST}" "${dry[@]}"; then
    history_add "rollback-failed" "${TARGET_VERSION}"
    fail "Falló el redespliegue de ${TARGET_VERSION} en ${HOST}." 3
  fi
  mkdir -p reports/ci 2>/dev/null || true
  if ! bash "${ENVIRONMENT_SCRIPT}" verify --env "${ENV_NAME}" --version "${TARGET_VERSION}" --host "${HOST}" \
       --report "reports/ci/rollback-health-${ENV_NAME}.json" "${dry[@]}"; then
    history_add "rollback-failed" "${TARGET_VERSION}"
    fail "La pila restaurada con ${TARGET_VERSION} no quedó saludable en ${HOST}." 3
  fi
}

# Redespliegue con docker compose local (agente o nodo con acceso a Docker).
redeploy_local() {
  prepare_env_file
  if [[ "${ENV_NAME}" != "dev" ]]; then
    log "Descargando imágenes ${REGISTRY_URL:-del registro}/circleguard/*:${TARGET_VERSION}"
    run dc pull --quiet
  fi
  log "Redesplegando la pila con IMAGE_TAG=${TARGET_VERSION}"
  if ! run dc up -d --remove-orphans --wait --wait-timeout "${WAIT_TIMEOUT}"; then
    history_add "rollback-failed" "${TARGET_VERSION}"
    [[ "${DRY_RUN}" == "1" ]] || dc ps -a || true
    fail "La pila restaurada con ${TARGET_VERSION} no quedó saludable." 3
  fi
  if [[ "${DRY_RUN}" != "1" ]]; then
    local bad
    bad="$(dc ps --format '{{.Service}} {{.Image}}' | awk -v v="${TARGET_VERSION}" '$2 ~ /\/circleguard\// && $2 !~ (":" v "$") {print $1}')"
    [[ -z "${bad}" ]] || fail "Servicios sin la versión ${TARGET_VERSION}: ${bad}" 3
  fi
}

cmd_rollback() {
  local requested="${1:-}"
  local current stable previous
  current="$(read_state current_version)"
  stable="$(read_state last_stable_version)"
  previous="$(read_state previous_stable_version)"

  if [[ -n "${requested}" ]]; then
    TARGET_VERSION="${requested}"
  elif [[ -n "${stable}" && "${stable}" != "${current}" ]]; then
    # El despliegue fallido dejó current != stable: se vuelve a la última estable.
    TARGET_VERSION="${stable}"
  elif [[ -n "${previous}" ]]; then
    # La versión actual ya estaba marcada estable: se vuelve a la estable anterior.
    TARGET_VERSION="${previous}"
  else
    fail "No hay una versión estable registrada en $(state_dir); use --to X.Y.Z." 2
  fi
  validate_version "${TARGET_VERSION}"

  log "Rollback: ${current:-desconocida} -> ${TARGET_VERSION}"
  history_add "rollback-start" "${TARGET_VERSION}"
  if [[ -n "${HOST}" ]]; then
    redeploy_remote
  else
    redeploy_local
  fi

  write_state current_version "${TARGET_VERSION}"
  write_state last_stable_version "${TARGET_VERSION}"
  history_add "rollback-ok" "${TARGET_VERSION}"
  log "Rollback completado: ${ENV_NAME} ejecuta ${TARGET_VERSION} y está saludable."
}

cmd_status() {
  printf 'Ambiente           : %s\n' "${ENV_NAME}"
  printf 'Versión actual     : %s\n' "$(read_state current_version || true)"
  printf 'Última estable     : %s\n' "$(read_state last_stable_version || true)"
  printf 'Estable anterior   : %s\n' "$(read_state previous_stable_version || true)"
  if [[ -s "$(state_dir)/history.tsv" ]]; then
    printf 'Historial (últimos 10):\n'
    tail -n 10 "$(state_dir)/history.tsv" | sed 's/^/  /'
  fi
}

COMMAND="${1:-}"; shift || true
case "${COMMAND}" in
  mark-deployed)
    ENV_NAME="${1:-}"; validate_env "${ENV_NAME}"
    [[ -n "${2:-}" ]] || fail "Uso: rollback.sh mark-deployed <env> <version>"
    cmd_mark_deployed "$2" ;;
  mark-stable)
    ENV_NAME="${1:-}"; validate_env "${ENV_NAME}"
    [[ -n "${2:-}" ]] || fail "Uso: rollback.sh mark-stable <env> <version>"
    cmd_mark_stable "$2" ;;
  rollback)
    ENV_NAME="${1:-}"; validate_env "${ENV_NAME}"; shift
    TO=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --to) TO="${2:?Falta valor para --to}"; shift 2 ;;
        --host) HOST="${2:?Falta valor para --host}"; shift 2 ;;
        *) fail "Opción desconocida: $1" ;;
      esac
    done
    cmd_rollback "${TO}" ;;
  status)
    ENV_NAME="${1:-}"; validate_env "${ENV_NAME}"
    cmd_status ;;
  -h|--help|"") usage ;;
  *) fail "Comando desconocido: ${COMMAND}" ;;
esac
