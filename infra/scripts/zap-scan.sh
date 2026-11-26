#!/usr/bin/env bash
# =============================================================================
# CircleGuard — OWASP ZAP baseline contra un ambiente desplegado (US-44)
#
# Uso:
#   zap-scan.sh --env dev --host 52.15.165.116   # nodo compose (SSH_KEY / SSH_USER del entorno)
#   zap-scan.sh --env dev --k8s                  # clúster k8s (US-39), KUBECONFIG del entorno
#   zap-scan.sh --env dev --local                # pila local (deploy/compose/smoke-up.sh KEEP_UP=1)
#
# Escanea con zap-baseline.py (araña + reglas pasivas, sin ataques) tres objetivos:
#   web      cliente web (puerto 8080 + offset del ambiente)
#   auth     API de auth-service (8180)        gateway  validación del QR (8087)
# Los alcanza igual que deploy/scripts/run-e2e.sh: túnel SSH hacia el nodo, port-forward de
# kubectl o los puertos publicados en local. ZAP corre en Docker; dentro de Jenkins comparte
# la red del contenedor del agente para ver los túneles en 127.0.0.1.
#
# Política (US-44 CA2): una alerta de riesgo ALTO por encima de ZAP_MAX_HIGH (0) hace que el
# script termine con 1. Las alertas MEDIAS y BAJAS se reportan sin fallar. Las reglas que el
# equipo decide ignorar viven en .zap/baseline-rules.tsv, cada una con su justificación.
#
# Reportes (US-44 CA1) en reports/zap/<env>/:
#   <objetivo>.html / .json / .md    reporte de ZAP     junit/<objetivo>.xml  JUnit para Jenkins
#   summary.json                      alertas por riesgo y objetivo, y el resultado de la política
#
# Salida: 0 dentro del umbral, 1 umbral superado, 2 uso inválido, 3 ZAP o los objetivos fallaron.
# Variables: ZAP_IMAGE, ZAP_MAX_HIGH (0), ZAP_TARGETS ("web auth gateway"), ZAP_MINUTES (2),
#   ZAP_DOCKER_NETWORK, REPORT_DIR, SSH_PORT, SSH_KNOWN_HOSTS, K8S_NAMESPACE, DRY_RUN=1.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZAP_IMAGE="${ZAP_IMAGE:-zaproxy/zap-stable:2.17.0}"
MAX_HIGH="${ZAP_MAX_HIGH:-0}"
MINUTES="${ZAP_MINUTES:-2}"
RULES_FILE="${ZAP_RULES_FILE:-${ROOT_DIR}/.zap/baseline-rules.tsv}"
DRY_RUN="${DRY_RUN:-0}"
read -r -a TARGETS <<< "${ZAP_TARGETS:-web auth gateway}"

log()  { printf '[zap-us44] %s\n' "$*" >&2; }
fail() { printf '[zap-us44][ERROR] %s\n' "$1" >&2; exit "${2:-2}"; }

ENV_NAME=""; HOST=""; MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)   ENV_NAME="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --host)  HOST="${2:-}"; MODE=ssh; shift $(( $# > 1 ? 2 : 1 )) ;;
    --k8s)   MODE=k8s; shift ;;
    --local) MODE=local; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "opción desconocida: $1" ;;
  esac
done

case "${ENV_NAME}" in
  dev) offset=0 ;; stage) offset=1000 ;;
  prod) fail "ZAP no se ejecuta contra prod: el escaneo genera tráfico y datos de prueba" ;;
  *) fail "--env inválido '${ENV_NAME}' (use dev o stage)" ;;
esac
[[ -n "${MODE}" ]] || fail "indique --host <ip>, --k8s o --local"
[[ "${MODE}" != ssh || -n "${HOST}" ]] || fail "--host requiere una IP o nombre"
[[ "${MAX_HIGH}" =~ ^[0-9]+$ ]] || fail "ZAP_MAX_HIGH debe ser un entero (actual: '${MAX_HIGH}')"

# objetivo -> puerto publicado en el nodo (deploy/compose/docker-compose.<env>.yml) y puerto del túnel
declare -A REMOTE_PORT=([web]=$((8080 + offset)) [auth]=$((8180 + offset)) [gateway]=$((8087 + offset)))
declare -A LOCAL_PORT=([web]=38080 [auth]=38180 [gateway]=38087)
declare -A K8S_SVC=([web]="${K8S_SVC_WEB:-web-client}" [auth]="${K8S_SVC_AUTH:-auth-service}" [gateway]="${K8S_SVC_GATEWAY:-gateway-service}")
declare -A K8S_PORT=([web]=8080 [auth]=8180 [gateway]=8087)
for t in "${TARGETS[@]}"; do [[ -n "${REMOTE_PORT[$t]:-}" ]] || fail "objetivo desconocido '${t}' (use web, auth, gateway)"; done

REPORT_DIR="${REPORT_DIR:-${ROOT_DIR}/reports/zap/${ENV_NAME}}"
mkdir -p "${REPORT_DIR}/junit"

run() { if [[ "${DRY_RUN}" == 1 ]]; then { printf 'DRY_RUN:'; printf ' %q' "$@"; printf '\n'; } >&2; else "$@"; fi; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

BG_PIDS=()
cleanup() { local p; for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "${p}" 2>/dev/null || true; done; }
trap cleanup EXIT

wait_ports() {
  local ok t
  for _ in $(seq 1 60); do
    ok=true
    for t in "${TARGETS[@]}"; do port_open "${LOCAL_PORT[$t]}" || { ok=false; break; }; done
    ${ok} && return 0
    sleep 0.5
  done
  return 1
}

# --- Acceso a los objetivos: puertos que ZAP verá en 127.0.0.1 (o en el host local) ---------
declare -A SCAN_PORT
case "${MODE}" in
  local)
    for t in "${TARGETS[@]}"; do SCAN_PORT[$t]="${REMOTE_PORT[$t]}"; done ;;
  ssh)
    forwards=()
    for t in "${TARGETS[@]}"; do
      forwards+=(-L "127.0.0.1:${LOCAL_PORT[$t]}:127.0.0.1:${REMOTE_PORT[$t]}")
      SCAN_PORT[$t]="${LOCAL_PORT[$t]}"
    done
    ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30)
    [[ -n "${SSH_KEY:-}" ]] && ssh_opts=(-i "${SSH_KEY}" "${ssh_opts[@]}")
    [[ -n "${SSH_PORT:-}" ]] && ssh_opts+=(-o "Port=${SSH_PORT}")
    [[ -n "${SSH_KNOWN_HOSTS:-}" ]] && ssh_opts+=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}")
    if [[ "${DRY_RUN}" == 1 ]]; then
      run ssh "${ssh_opts[@]}" -N "${forwards[@]}" "${SSH_USER:-ec2-user}@${HOST}"
    else
      log "Abriendo túneles SSH hacia ${HOST} (${#TARGETS[@]} objetivos)"
      ssh "${ssh_opts[@]}" -N "${forwards[@]}" "${SSH_USER:-ec2-user}@${HOST}" </dev/null &
      BG_PIDS+=("$!")
      wait_ports || fail "los túneles SSH hacia ${HOST} no quedaron disponibles" 3
    fi ;;
  k8s)
    namespace="${K8S_NAMESPACE:-circleguard-${ENV_NAME}}"
    for t in "${TARGETS[@]}"; do
      SCAN_PORT[$t]="${LOCAL_PORT[$t]}"
      if [[ "${DRY_RUN}" == 1 ]]; then
        run kubectl -n "${namespace}" port-forward "svc/${K8S_SVC[$t]}" "${LOCAL_PORT[$t]}:${K8S_PORT[$t]}"
      else
        kubectl -n "${namespace}" port-forward "svc/${K8S_SVC[$t]}" "${LOCAL_PORT[$t]}:${K8S_PORT[$t]}" >/dev/null 2>&1 &
        BG_PIDS+=("$!")
      fi
    done
    [[ "${DRY_RUN}" == 1 ]] || wait_ports || fail "los port-forward hacia ${namespace} no quedaron disponibles" 3 ;;
esac

# --- Red del contenedor de ZAP --------------------------------------------------------------
# Jenkins corre en Docker: ZAP comparte la red del contenedor del agente (ve sus túneles).
# En Linux sin contenedor, la red del host. En Docker Desktop (Windows/macOS), host.docker.internal.
scan_host=127.0.0.1
docker_net=()
if [[ -n "${ZAP_DOCKER_NETWORK:-}" ]]; then
  docker_net=(--network "${ZAP_DOCKER_NETWORK}")
elif [[ -f /.dockerenv ]]; then
  docker_net=(--network "container:$(cat /etc/hostname)")
elif [[ "$(uname -s)" == Linux ]]; then
  docker_net=(--network host)
else
  scan_host=host.docker.internal
fi

# --- Escaneo ---------------------------------------------------------------------------------
zap_failed=0
declare -A HIGH MEDIUM LOW
for t in "${TARGETS[@]}"; do
  url="http://${scan_host}:${SCAN_PORT[$t]}/"
  name="zap-us44-${ENV_NAME}-${t}-$$"
  log "Escaneando ${t} (${url}) con ${ZAP_IMAGE}"
  zap_args=(zap-baseline.py -t "${url}" -m "${MINUTES}" -I -r "${t}.html" -J "${t}.json" -w "${t}.md")
  [[ -f "${RULES_FILE}" ]] && zap_args+=(-c baseline-rules.tsv)

  # Sin montar carpetas del agente: /zap/wrk es un volumen anónimo y los reportes se copian con
  # docker cp (las rutas del workspace de Jenkins no existen en el host de Docker).
  run docker create --name "${name}" "${docker_net[@]}" -v /zap/wrk "${ZAP_IMAGE}" "${zap_args[@]}" >/dev/null
  [[ -f "${RULES_FILE}" ]] && run docker cp "${RULES_FILE}" "${name}:/zap/wrk/baseline-rules.tsv"
  rc=0
  run docker start -a "${name}" >&2 || rc=$?
  run docker cp "${name}:/zap/wrk/." "${REPORT_DIR}/" || true
  run docker rm -v "${name}" >/dev/null || true
  rm -f "${REPORT_DIR}/baseline-rules.tsv"

  # zap-baseline con -I: 0 = sin FAIL, 1 = alguna regla FAIL de baseline-rules.tsv, 3 = error de ZAP.
  if [[ "${DRY_RUN}" != 1 && ( ${rc} -ge 3 || ! -s "${REPORT_DIR}/${t}.json" ) ]]; then
    log "ERROR: ZAP no pudo escanear ${t} (código ${rc})"
    zap_failed=1; HIGH[$t]=0; MEDIUM[$t]=0; LOW[$t]=0
    continue
  fi
  json="${REPORT_DIR}/${t}.json"
  HIGH[$t]=$( (grep -o '"riskcode": *"3"' "${json}" 2>/dev/null || true) | wc -l | tr -d ' ')
  MEDIUM[$t]=$( (grep -o '"riskcode": *"2"' "${json}" 2>/dev/null || true) | wc -l | tr -d ' ')
  LOW[$t]=$( (grep -o '"riskcode": *"1"' "${json}" 2>/dev/null || true) | wc -l | tr -d ' ')
  [[ ${rc} -eq 1 ]] && HIGH[$t]=$(( HIGH[$t] > 0 ? HIGH[$t] : 1 ))   # una regla FAIL cuenta como alto

  failures=$(( HIGH[$t] > 0 ? 1 : 0 ))
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="zap-baseline-%s-%s" tests="1" failures="%s">\n' "${ENV_NAME}" "${t}" "${failures}"
    printf '  <testcase classname="zap.%s" name="sin alertas de riesgo alto">\n' "${t}"
    [[ ${failures} -eq 1 ]] && printf '    <failure message="%s alertas de riesgo alto (ver %s.html)"/>\n' "${HIGH[$t]}" "${t}"
    printf '  </testcase>\n</testsuite>\n'
  } > "${REPORT_DIR}/junit/${t}.xml"
  log "${t}: alto=${HIGH[$t]} medio=${MEDIUM[$t]} bajo=${LOW[$t]}"
done

total_high=0
for t in "${TARGETS[@]}"; do total_high=$(( total_high + ${HIGH[$t]:-0} )); done
result=PASS
[[ ${total_high} -gt ${MAX_HIGH} ]] && result=FAIL
[[ ${zap_failed} -eq 1 ]] && result=ERROR

{
  printf '{\n  "env": "%s",\n  "image": "%s",\n  "maxHigh": %s,\n  "result": "%s",\n  "targets": {' "${ENV_NAME}" "${ZAP_IMAGE}" "${MAX_HIGH}" "${result}"
  sep=""
  for t in "${TARGETS[@]}"; do
    printf '%s\n    "%s": {"high": %s, "medium": %s, "low": %s}' "${sep}" "${t}" "${HIGH[$t]:-0}" "${MEDIUM[$t]:-0}" "${LOW[$t]:-0}"
    sep=","
  done
  printf '\n  }\n}\n'
} > "${REPORT_DIR}/summary.json"

case "${result}" in
  PASS)  log "Resultado: dentro del umbral (riesgo alto ${total_high} <= ${MAX_HIGH}). Reportes en ${REPORT_DIR}"; exit 0 ;;
  FAIL)  log "Resultado: ${total_high} alertas de riesgo alto superan el umbral (${MAX_HIGH}). Ver ${REPORT_DIR}"; exit 1 ;;
  ERROR) log "Resultado: ZAP no pudo escanear todos los objetivos. Ver ${REPORT_DIR}"; exit 3 ;;
esac
