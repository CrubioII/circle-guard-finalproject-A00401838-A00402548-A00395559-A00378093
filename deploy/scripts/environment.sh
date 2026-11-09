#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Orquestador de ambientes invocado por Jenkins (US-13)
#
# Acciones:
#   deploy  Copia por SCP el compose del ambiente (US-08) y los scripts de despliegue al nodo
#           (/opt/circleguard/<env>/compose/stack) y ejecuta deploy-env.sh por SSH.
#           La contraseña del registro viaja por stdin (nunca en argumentos ni en disco).
#   verify  Ejecuta verify-env-health.sh por SSH y guarda el reporte JSON (--report).
#
# Credenciales (las inyecta withCredentials en el Jenkinsfile, nunca se versionan):
#   SSH_KEY / SSH_USER                   -> sshUserPrivateKey 'circleguard-env-ssh'
#   REGISTRY_USER / REGISTRY_PASSWORD    -> usernamePassword 'nexus-credentials'
#
# Uso:
#   deploy/scripts/environment.sh deploy --env dev --version 1.4.0 --host 52.15.213.209
#   deploy/scripts/environment.sh verify --env dev --version 1.4.0 --host 52.15.213.209 \
#       --report reports/ci/health-dev.json
#   --local    ejecuta los scripts en esta máquina (pruebas; usa ENV_FILE/COMPOSE_FILE locales)
#   --dry-run  imprime los comandos SSH/SCP sin ejecutarlos
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/deploy/scripts"

ACTION="${1:-}"; shift || true
ENV_NAME=""; VERSION=""; HOST=""; REPORT=""; LOCAL=false; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --host) HOST="${2:?}"; shift 2 ;;
    --report) REPORT="${2:?}"; shift 2 ;;
    --local) LOCAL=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "[environment] opción desconocida: $1" >&2; exit 2 ;;
  esac
done

SEMVER_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
log() { printf '[environment][%s][%s] %s\n' "${ACTION}" "${ENV_NAME:-?}" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

case "${ACTION}" in deploy|verify) ;; *) die "acción inválida '${ACTION}' (deploy|verify)" ;; esac
case "${ENV_NAME}" in dev|stage|prod) ;; *) die "--env inválido '${ENV_NAME}' (dev|stage|prod)" ;; esac
[[ "${VERSION}" =~ ${SEMVER_REGEX} ]] || die "--version '${VERSION}' no cumple SemVer (nunca 'latest')"
${LOCAL} || [[ -n "${HOST}" ]] || die "--host es obligatorio (o use --local)"

REMOTE_DIR="${REMOTE_BASE_DIR:-/opt/circleguard}/${ENV_NAME}/compose/stack"
COMPOSE_SRC="${ROOT_DIR}/deploy/compose/docker-compose.${ENV_NAME}.yml"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
          -o ServerAliveInterval=30 -o ServerAliveCountMax=10)
[[ -n "${SSH_KEY:-}" ]] && SSH_OPTS=(-i "${SSH_KEY}" "${SSH_OPTS[@]}")
# Opcionales: puerto SSH no estándar y archivo known_hosts dedicado (válidos para ssh y scp).
[[ -n "${SSH_PORT:-}" ]] && SSH_OPTS+=(-o "Port=${SSH_PORT}")
[[ -n "${SSH_KNOWN_HOSTS:-}" ]] && SSH_OPTS+=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}")
TARGET="${SSH_USER}@${HOST}"

run() {
  if ${DRY_RUN}; then printf '[dry-run] %s\n' "$*" >&2; else "$@"; fi
}
# Variables para el script remoto, citadas de forma segura para el shell remoto.
remote_env() {
  local out="" kv
  for kv in "$@"; do out+="$(printf '%q' "${kv}") "; done
  printf '%s' "${out}"
}

if [[ "${ACTION}" == "deploy" ]]; then
  [[ -f "${COMPOSE_SRC}" ]] || die "no existe ${COMPOSE_SRC}"
  if ${LOCAL}; then where="local"; else where="${TARGET}"; fi
  log "Desplegando ${VERSION} en ${ENV_NAME} (${where})"
  pass_stdin=0
  [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_PASSWORD:-}" ]] && pass_stdin=1

  if ${LOCAL}; then
    if [[ ${pass_stdin} -eq 1 ]]; then
      printf '%s' "${REGISTRY_PASSWORD}" | REGISTRY_USER="${REGISTRY_USER}" REGISTRY_PASSWORD_STDIN=1 \
        IMAGE_TAG="${VERSION}" COMPOSE_FILE="${COMPOSE_FILE:-${COMPOSE_SRC}}" bash "${SCRIPTS_DIR}/deploy-env.sh" "${ENV_NAME}"
    else
      IMAGE_TAG="${VERSION}" COMPOSE_FILE="${COMPOSE_FILE:-${COMPOSE_SRC}}" bash "${SCRIPTS_DIR}/deploy-env.sh" "${ENV_NAME}"
    fi
    exit 0
  fi

  # 1. Sincroniza compose + scripts (el nodo siempre despliega el manifiesto del commit en curso).
  run ssh "${SSH_OPTS[@]}" "${TARGET}" "mkdir -p $(printf '%q' "${REMOTE_DIR}")"
  run scp "${SSH_OPTS[@]}" -q "${COMPOSE_SRC}" "${SCRIPTS_DIR}/deploy-env.sh" "${SCRIPTS_DIR}/verify-env-health.sh" \
      "${TARGET}:${REMOTE_DIR}/"

  # 2. Despliegue remoto; la contraseña del registro entra por stdin.
  envs=(IMAGE_TAG="${VERSION}" REGISTRY_PASSWORD_STDIN="${pass_stdin}")
  [[ ${pass_stdin} -eq 1 ]] && envs+=(REGISTRY_USER="${REGISTRY_USER}")
  [[ -n "${REGISTRY_URL:-}" ]] && envs+=(REGISTRY_URL="${REGISTRY_URL}")
  remote_cmd="$(remote_env "${envs[@]}")bash $(printf '%q' "${REMOTE_DIR}/deploy-env.sh") ${ENV_NAME}"
  if ${DRY_RUN}; then
    run ssh "${SSH_OPTS[@]}" "${TARGET}" "${remote_cmd}"
  elif [[ ${pass_stdin} -eq 1 ]]; then
    printf '%s' "${REGISTRY_PASSWORD}" | ssh "${SSH_OPTS[@]}" "${TARGET}" "${remote_cmd}"
  else
    ssh "${SSH_OPTS[@]}" "${TARGET}" "${remote_cmd}" </dev/null
  fi
  log "Despliegue de ${VERSION} en ${ENV_NAME} completado"
  exit 0
fi

# ACTION == verify
report_tmp="$(mktemp)"
trap 'rm -f "${report_tmp}"' EXIT
rc=0
if ${LOCAL}; then
  IMAGE_TAG="${VERSION}" COMPOSE_FILE="${COMPOSE_FILE:-${COMPOSE_SRC}}" \
    bash "${SCRIPTS_DIR}/verify-env-health.sh" "${ENV_NAME}" >"${report_tmp}" || rc=$?
else
  remote_cmd="$(remote_env IMAGE_TAG="${VERSION}")bash $(printf '%q' "${REMOTE_DIR}/verify-env-health.sh") ${ENV_NAME}"
  if ${DRY_RUN}; then
    run ssh "${SSH_OPTS[@]}" "${TARGET}" "${remote_cmd}"
    exit 0
  fi
  ssh "${SSH_OPTS[@]}" "${TARGET}" "${remote_cmd}" </dev/null >"${report_tmp}" || rc=$?
fi

if [[ -n "${REPORT}" ]]; then
  mkdir -p "$(dirname "${REPORT}")"
  if [[ -s "${report_tmp}" ]]; then
    cp "${report_tmp}" "${REPORT}"
  else
    printf '{"env":"%s","expectedTag":"%s","status":"FAIL","failures":-1,"reason":"sin respuesta del nodo (exit %d)"}\n' \
      "${ENV_NAME}" "${VERSION}" "${rc}" >"${REPORT}"
  fi
  log "Reporte de salud: ${REPORT}"
fi
cat "${report_tmp}"
[[ ${rc} -eq 0 ]] && log "Healthchecks de ${ENV_NAME} OK para ${VERSION}" || log "Healthchecks de ${ENV_NAME} FALLARON (exit ${rc})"
exit "${rc}"
