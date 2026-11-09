#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Ejecución de los flujos E2E contra un ambiente desplegado (US-13 / CA2)
#
# Abre túneles SSH desde el agente de Jenkins hacia los puertos publicados del nodo
# (los security groups de US-05 solo exponen 22/8080/8180/8087), apunta las variables
# E2E_*_URL a esos túneles y ejecuta la suite Playwright de e2e/ (contrato ampliable por US-17).
# Reportes: reports/e2e/junit.xml y reports/e2e/results.json. Exit != 0 si algún flujo falla.
#
# Uso:
#   deploy/scripts/run-e2e.sh --env dev --host 52.15.213.209   # SSH_KEY / SSH_USER del entorno
#   deploy/scripts/run-e2e.sh --env dev --local                 # pila local, puertos de dev
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_NAME=""; HOST=""; LOCAL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --host) HOST="${2:?}"; shift 2 ;;
    --local) LOCAL=true; shift ;;
    *) echo "[run-e2e] opción desconocida: $1" >&2; exit 2 ;;
  esac
done
log() { printf '[run-e2e][%s] %s\n' "${ENV_NAME:-?}" "$*" >&2; }

case "${ENV_NAME}" in
  dev) offset=0 ;; stage) offset=1000 ;; prod) offset=2000 ;;
  *) log "ERROR: --env inválido '${ENV_NAME}'"; exit 2 ;;
esac
${LOCAL} || [[ -n "${HOST}" ]] || { log "ERROR: --host es obligatorio (o use --local)"; exit 2; }

# servicio -> puerto publicado en el nodo según deploy/compose/docker-compose.<env>.yml
declare -A REMOTE_PORT=(
  [AUTH]=$((8180 + offset)) [IDENTITY]=$((8083 + offset)) [PROMOTION]=$((8088 + offset))
  [FORM]=$((8086 + offset)) [GATEWAY]=$((8087 + offset)) [WEB]=$((8080 + offset))
)
# Puertos locales del túnel (rango 28xxx para no chocar con Jenkins en 8080)
declare -A LOCAL_PORT=(
  [AUTH]=28180 [IDENTITY]=28083 [PROMOTION]=28088 [FORM]=28086 [GATEWAY]=28087 [WEB]=28080
)

TUNNEL_PID=""
close_tunnel() {
  if [[ -n "${TUNNEL_PID}" ]] && kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
    log "Túnel SSH cerrado"
  fi
}
trap close_tunnel EXIT

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

if ${LOCAL}; then
  for svc in "${!REMOTE_PORT[@]}"; do export "E2E_${svc}_URL=http://127.0.0.1:${REMOTE_PORT[$svc]}"; done
else
  # Destino del reenvío visto desde el nodo: 127.0.0.1 (puertos publicados por compose en el host).
  target="${E2E_TUNNEL_TARGET:-127.0.0.1}"
  forwards=()
  for svc in "${!REMOTE_PORT[@]}"; do
    forwards+=(-L "127.0.0.1:${LOCAL_PORT[$svc]}:${target}:${REMOTE_PORT[$svc]}")
    export "E2E_${svc}_URL=http://127.0.0.1:${LOCAL_PORT[$svc]}"
  done
  ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ExitOnForwardFailure=yes
            -o ServerAliveInterval=30)
  [[ -n "${SSH_KEY:-}" ]] && ssh_opts=(-i "${SSH_KEY}" "${ssh_opts[@]}")
  [[ -n "${SSH_PORT:-}" ]] && ssh_opts+=(-o "Port=${SSH_PORT}")
  [[ -n "${SSH_KNOWN_HOSTS:-}" ]] && ssh_opts+=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}")
  log "Abriendo túneles SSH hacia ${HOST} ($(( ${#forwards[@]} / 2 )) reenvíos de puerto)"
  ssh "${ssh_opts[@]}" -N "${forwards[@]}" "${SSH_USER:-ec2-user}@${HOST}" </dev/null &
  TUNNEL_PID=$!
  # Espera activa a que los 6 puertos locales del túnel acepten conexiones (máx. 30 s).
  for _ in $(seq 1 60); do
    kill -0 "${TUNNEL_PID}" 2>/dev/null || { log "ERROR: el túnel SSH terminó (¿reenvío rechazado o SSH caído?)"; exit 1; }
    all_up=true
    for svc in "${!LOCAL_PORT[@]}"; do port_open "${LOCAL_PORT[$svc]}" || { all_up=false; break; }; done
    ${all_up} && break
    sleep 0.5
  done
  ${all_up} || { log "ERROR: los puertos del túnel no quedaron disponibles"; exit 1; }
  log "Túneles listos (pid ${TUNNEL_PID})"
fi

export E2E_TARGET_ENV="${ENV_NAME}"
export E2E_REPORT_DIR="${E2E_REPORT_DIR:-${ROOT_DIR}/reports/e2e}"
export CI="${CI:-true}"
rm -rf "${E2E_REPORT_DIR}" && mkdir -p "${E2E_REPORT_DIR}"

cd "${ROOT_DIR}/e2e"
log "Instalando dependencias E2E (npm ci)"
npm ci --no-audit --no-fund --loglevel=error

log "Ejecutando flujos E2E contra ${ENV_NAME} (auth=${E2E_AUTH_URL}, gateway=${E2E_GATEWAY_URL}, web=${E2E_WEB_URL})"
rc=0
npx playwright test || rc=$?
if [[ ${rc} -eq 0 ]]; then log "E2E OK"; else log "E2E FALLÓ (exit ${rc}) — la promoción debe bloquearse"; fi
exit "${rc}"
