#!/usr/bin/env bash
# =============================================================================
# CircleGuard — E2E contra un ambiente desplegado: compuerta de promoción (US-13 / CA2)
#
# Ejecuta, contra los servicios REALES del ambiente, la suite Playwright de e2e/:
#   - proyecto `chromium`: flujos de negocio @us17 (US-17) y smoke @smoke (US-34) en el
#     navegador, con E2E_MOCK_API=false (sin simulaciones);
#   - proyecto `deployed-api`: contratos HTTP @deployed de tests/deployed/ (US-13).
#
# Remoto (Jenkins): abre túneles SSH hacia el nodo, porque los security groups de US-05 solo
# exponen 22/8080/8180/8087:
#   cliente web  -> localhost:${E2E_WEB_LOCAL_PORT:-8081}  (origen permitido por el CORS de
#                   auth-service: http://localhost:8080 / :8081; el 8080 del agente es Jenkins)
#   servicios    -> 127.0.0.1:28xxx; el fixture runtimeConfigFromEnv reescribe
#                   /runtime-config.js para que el navegador use esos túneles.
# Reportes: e2e/reports/<env>/{junit/results.xml,html}. Exit != 0 si falla cualquier flujo.
#
# Uso:
#   deploy/scripts/run-e2e.sh --env dev --host 52.15.213.209   # SSH_KEY / SSH_USER del entorno
#   deploy/scripts/run-e2e.sh --env dev --local                 # pila local (smoke-up.sh KEEP_UP=1)
# Opcionales: SSH_PORT, SSH_KNOWN_HOSTS, E2E_TUNNEL_TARGET (127.0.0.1), E2E_WEB_LOCAL_PORT (8081),
#   E2E_SKIP_BROWSER_INSTALL=1.
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
# Puertos locales del túnel. WEB debe ser un origen permitido por el CORS de auth-service.
WEB_LOCAL_PORT="${E2E_WEB_LOCAL_PORT:-8081}"
declare -A LOCAL_PORT=(
  [AUTH]=28180 [IDENTITY]=28083 [PROMOTION]=28088 [FORM]=28086 [GATEWAY]=28087 [WEB]=${WEB_LOCAL_PORT}
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
  for svc in AUTH IDENTITY PROMOTION FORM GATEWAY; do export "E2E_${svc}_URL=http://127.0.0.1:${REMOTE_PORT[$svc]}"; done
  # Origen http://localhost:8080 (permitido por CORS) = puerto publicado del web-client local.
  export E2E_WEB_URL="http://localhost:${REMOTE_PORT[WEB]}"
else
  # Destino del reenvío visto desde el nodo: 127.0.0.1 (puertos publicados por compose en el host).
  target="${E2E_TUNNEL_TARGET:-127.0.0.1}"
  forwards=()
  for svc in AUTH IDENTITY PROMOTION FORM GATEWAY; do
    forwards+=(-L "127.0.0.1:${LOCAL_PORT[$svc]}:${target}:${REMOTE_PORT[$svc]}")
    export "E2E_${svc}_URL=http://127.0.0.1:${LOCAL_PORT[$svc]}"
  done
  # 'localhost' liga IPv4 e IPv6: el navegador abre http://localhost:<puerto> como origen.
  forwards+=(-L "localhost:${WEB_LOCAL_PORT}:${target}:${REMOTE_PORT[WEB]}")
  export E2E_WEB_URL="http://localhost:${WEB_LOCAL_PORT}"

  ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ExitOnForwardFailure=yes
            -o ServerAliveInterval=30)
  [[ -n "${SSH_KEY:-}" ]] && ssh_opts=(-i "${SSH_KEY}" "${ssh_opts[@]}")
  [[ -n "${SSH_PORT:-}" ]] && ssh_opts+=(-o "Port=${SSH_PORT}")
  [[ -n "${SSH_KNOWN_HOSTS:-}" ]] && ssh_opts+=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}")
  log "Abriendo túneles SSH hacia ${HOST} ($(( ${#forwards[@]} / 2 )) reenvíos de puerto)"
  ssh "${ssh_opts[@]}" -N "${forwards[@]}" "${SSH_USER:-ec2-user}@${HOST}" </dev/null &
  TUNNEL_PID=$!
  # Espera activa a que los 6 puertos locales del túnel acepten conexiones (máx. 30 s).
  all_up=false
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

# Contrato con e2e/playwright.config.ts y e2e/support/fixtures.ts
export E2E_TARGET_ENV="${ENV_NAME}"
export BASE_URL="${E2E_WEB_URL}"
export E2E_MOCK_API=false
export E2E_RUNTIME_CONFIG_FROM_ENV=1
export E2E_REPORT_DIR="reports/${ENV_NAME}"
export CI="${CI:-true}"

cd "${ROOT_DIR}/e2e"
rm -rf "${E2E_REPORT_DIR}" "test-results/${ENV_NAME}"
log "Instalando dependencias E2E (npm ci)"
npm ci --no-audit --no-fund --loglevel=error
if [[ "${E2E_SKIP_BROWSER_INSTALL:-0}" != "1" ]]; then
  log "Instalando Chromium para Playwright"
  npx playwright install chromium >/dev/null
fi

log "Ejecutando E2E contra ${ENV_NAME}: web=${BASE_URL} auth=${E2E_AUTH_URL} gateway=${E2E_GATEWAY_URL} (APIs reales)"
rc=0
npx playwright test --project=chromium --project=deployed-api || rc=$?
if [[ ${rc} -eq 0 ]]; then log "E2E OK"; else log "E2E FALLÓ (exit ${rc}) — la promoción a stage debe bloquearse"; fi
exit "${rc}"
