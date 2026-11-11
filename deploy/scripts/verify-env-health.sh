#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Verificación de salud post-despliegue de un ambiente (US-13 / CA1)
#
# Se ejecuta EN el nodo (vía SSH desde Jenkins) o en local. Verifica:
#   1. Los 12 contenedores de la pila existen y están "healthy" (espera hasta HEALTH_TIMEOUT).
#   2. Las 6 imágenes propias ejecutan exactamente <registro>/circleguard/<svc>:${IMAGE_TAG}.
#   3. Sondeo funcional dentro de cada contenedor (no depende de puertos/security groups):
#      /actuator/health/readiness == UP en los 5 servicios núcleo y /healthz en web-client.
#
# Salida: reporte JSON por stdout (Jenkins lo guarda en reports/ci/health-<env>.json);
# los logs legibles van por stderr. Exit 0 = PASS, 1 = FAIL.
#
# Uso: IMAGE_TAG=1.4.0 bash verify-env-health.sh dev
# Variables opcionales: DEPLOY_BASE_DIR, ENV_FILE, COMPOSE_FILE, HEALTH_TIMEOUT (300 s).
# =============================================================================
set -uo pipefail

ENV_NAME="${1:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
DEPLOY_BASE_DIR="${DEPLOY_BASE_DIR:-/opt/circleguard}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

log() { printf '[verify-health][%s] %s\n' "${ENV_NAME:-?}" "$*" >&2; }

case "${ENV_NAME}" in
  dev|stage|prod) ;;
  *) log "ERROR: ambiente inválido '${ENV_NAME}'"; exit 1 ;;
esac
[[ -n "${IMAGE_TAG}" ]] || { log "ERROR: IMAGE_TAG es obligatorio"; exit 1; }

BASE_DIR="${DEPLOY_BASE_DIR}/${ENV_NAME}"
ENV_FILE="${ENV_FILE:-${BASE_DIR}/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${BASE_DIR}/compose/stack/docker-compose.${ENV_NAME}.yml}"
export IMAGE_TAG
dc() { docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"; }

MIDDLEWARE=(postgres neo4j zookeeper kafka redis openldap)
CORE=(auth-service identity-service promotion-service form-service gateway-service)
OWN=("${CORE[@]}" web-client)
ALL=("${MIDDLEWARE[@]}" "${OWN[@]}")

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'; }

# 1. Esperar a que todos estén healthy
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
while :; do
  unhealthy=()
  for svc in "${ALL[@]}"; do
    h="$(dc ps --format '{{.Health}}' "${svc}" 2>/dev/null | head -n 1)"
    [[ "${h}" == "healthy" ]] || unhealthy+=("${svc}:${h:-missing}")
  done
  [[ ${#unhealthy[@]} -eq 0 ]] && break
  if (( $(date +%s) >= deadline )); then
    log "Tiempo agotado (${HEALTH_TIMEOUT}s); no saludables: ${unhealthy[*]}"
    break
  fi
  sleep 5
done

failures=0
entries=()
for svc in "${ALL[@]}"; do
  health="$(dc ps --format '{{.Health}}' "${svc}" 2>/dev/null | head -n 1)"
  image="$(dc ps --format '{{.Image}}' "${svc}" 2>/dev/null | head -n 1)"
  health="${health:-missing}"
  ok=true
  reason=""

  [[ "${health}" == "healthy" ]] || { ok=false; reason="health=${health}"; }

  # 2. Versión exacta en las imágenes propias
  if [[ " ${OWN[*]} " == *" ${svc} "* ]]; then
    if [[ "${image}" != */circleguard/${svc}:"${IMAGE_TAG}" ]]; then
      ok=false; reason="${reason:+${reason}; }imagen '${image}' != */circleguard/${svc}:${IMAGE_TAG}"
    fi
  elif [[ -z "${image}" || "${image}" == *":latest" ]]; then
    ok=false; reason="${reason:+${reason}; }imagen de terceros sin tag fijo '${image}'"
  fi

  # 3. Sondeo funcional dentro del contenedor
  probe="n/a"
  if [[ " ${CORE[*]} " == *" ${svc} "* ]]; then
    body="$(dc exec -T "${svc}" sh -c 'wget -q -T 5 -O - "http://127.0.0.1:${SERVER_PORT}/actuator/health/readiness"' 2>/dev/null)"
    if printf '%s' "${body}" | grep -q '"status":"UP"'; then probe="readiness UP"; else
      probe="readiness FAIL"; ok=false; reason="${reason:+${reason}; }readiness != UP"
    fi
  elif [[ "${svc}" == "web-client" ]]; then
    body="$(dc exec -T "${svc}" sh -c 'wget -q -T 5 -O - http://127.0.0.1:8080/healthz' 2>/dev/null)"
    if printf '%s' "${body}" | grep -q '"status":"UP"'; then probe="healthz UP"; else
      probe="healthz FAIL"; ok=false; reason="${reason:+${reason}; }/healthz != UP"
    fi
  fi

  if ${ok}; then
    log "[OK]   ${svc} | ${health} | ${image} | ${probe}"
  else
    failures=$((failures + 1))
    log "[FAIL] ${svc} | ${reason}"
  fi
  entries+=("{\"service\":\"${svc}\",\"health\":\"$(json_escape "${health}")\",\"image\":\"$(json_escape "${image}")\",\"probe\":\"${probe}\",\"ok\":${ok},\"reason\":\"$(json_escape "${reason}")\"}")
done

status="PASS"
[[ ${failures} -eq 0 ]] || status="FAIL"
services_json="$(IFS=,; printf '%s' "${entries[*]}")"
printf '{"env":"%s","expectedTag":"%s","status":"%s","failures":%d,"checkedAt":"%s","host":"%s","services":[%s]}\n' \
  "${ENV_NAME}" "${IMAGE_TAG}" "${status}" "${failures}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(json_escape "$(hostname)")" "${services_json}"

log "Resultado: ${status} (${failures} fallos de ${#ALL[@]} contenedores)"
[[ "${status}" == "PASS" ]]
