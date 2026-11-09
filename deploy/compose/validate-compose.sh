#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Validación de los compose por ambiente (US-08 / subtarea 3)
#
# Para cada deploy/compose/docker-compose.{dev,stage,prod}.yml verifica:
#   CA1  La pila incluye el middleware completo (postgres, neo4j, zookeeper, kafka,
#        redis, openldap), los 5 servicios núcleo y el cliente web.
#   CA2  Ninguna imagen usa :latest ni carece de tag; las imágenes propias resuelven
#        exactamente a ${REGISTRY_URL}/circleguard/<servicio>:${IMAGE_TAG} con IMAGE_TAG SemVer,
#        y compose se niega a renderizar si IMAGE_TAG/APP_VERSION no están definidos.
#   CA3  Todo contenedor tiene healthcheck funcional y todo depends_on usa
#        condition: service_healthy.
#   +    stage/prod exigen secretos (fallan sin POSTGRES_PASSWORD) y no publican middleware.
#
# No arranca contenedores (para eso: deploy/compose/smoke-up.sh).
#
# Uso:
#   bash deploy/compose/validate-compose.sh                 # los 3 ambientes
#   IMAGE_TAG=1.4.2 bash deploy/compose/validate-compose.sh stage prod
# Requisitos: docker compose v2 y jq (si falta jq se usa la imagen ghcr.io/jqlang/jq).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_DIR="${ROOT_DIR}/deploy/compose"
INJECT_SCRIPT="${ROOT_DIR}/infra/bootstrap/inject-jenkins-secrets.sh"

ENVS=("$@")
[[ ${#ENVS[@]} -eq 0 ]] && ENVS=(dev stage prod)

IMAGE_TAG="${IMAGE_TAG:-${APP_VERSION:-1.0.0}}"
REGISTRY_URL="${REGISTRY_URL:-registry.circleguard.local:5000}"
SEMVER_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

MIDDLEWARE=(postgres neo4j zookeeper kafka redis openldap)
OWN_SERVICES=(auth-service identity-service promotion-service form-service gateway-service web-client)
REQUIRED=("${MIDDLEWARE[@]}" "${OWN_SERVICES[@]}")

JQ_IMAGE="ghcr.io/jqlang/jq:1.7.1"
if command -v jq >/dev/null 2>&1; then
  jqx() { jq "$@"; }
else
  jqx() { docker run --rm -i "${JQ_IMAGE}" "$@"; }
fi

failures=0
checks=0
pass() { checks=$((checks + 1)); printf '   [OK]   %s\n' "$*"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '   [FAIL] %s\n' "$*"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "=== Validación compose por ambiente (US-08) | IMAGE_TAG=${IMAGE_TAG} | REGISTRY_URL=${REGISTRY_URL} ==="

if [[ "${IMAGE_TAG}" =~ ${SEMVER_REGEX} ]]; then
  pass "IMAGE_TAG '${IMAGE_TAG}' cumple SemVer 2.0"
else
  fail "IMAGE_TAG '${IMAGE_TAG}' NO cumple SemVer 2.0 (ej. 1.2.0)"
  exit 1
fi

for env_name in "${ENVS[@]}"; do
  compose_file="${COMPOSE_DIR}/docker-compose.${env_name}.yml"
  echo
  echo "--- Ambiente: ${env_name} (${compose_file#"${ROOT_DIR}/"}) ---"
  if [[ ! -f "${compose_file}" ]]; then
    fail "No existe ${compose_file}"
    continue
  fi

  # Archivo de entorno efímero con secretos aleatorios generado por el mismo inyector de US-05.
  env_file="${TMP_DIR}/.env.${env_name}"
  IMAGE_TAG="${IMAGE_TAG}" PUBLIC_HOST="localhost" \
    bash "${INJECT_SCRIPT}" --env "${env_name}" --output "${env_file}" --registry-url "${REGISTRY_URL}" >/dev/null

  # 1. Renderizado del manifiesto (sintaxis + interpolación)
  json_file="${TMP_DIR}/${env_name}.json"
  if docker compose --env-file "${env_file}" -f "${compose_file}" config --format json >"${json_file}" 2>"${TMP_DIR}/${env_name}.err"; then
    pass "docker compose config renderiza sin errores"
  else
    fail "docker compose config falló: $(tr '\n' ' ' <"${TMP_DIR}/${env_name}.err")"
    continue
  fi

  # 2. CA1 — servicios requeridos
  mapfile -t present < <(jqx -r '.services | keys[]' <"${json_file}" | tr -d '\r')
  missing=()
  for svc in "${REQUIRED[@]}"; do
    [[ " ${present[*]} " == *" ${svc} "* ]] || missing+=("${svc}")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "CA1: ${#REQUIRED[@]} servicios requeridos presentes (middleware + 5 núcleo + web-client)"
  else
    fail "CA1: faltan servicios: ${missing[*]}"
  fi

  # 3. CA2 — imágenes: con tag explícito y nunca latest
  bad_images="$(jqx -r '.services | to_entries[] | (.value.image // "") as $i
      | ($i | split("/") | last) as $last
      | select($i == "" or ($last | contains(":") | not) or ($last | test(":latest$")))
      | "\(.key)=\($i)"' <"${json_file}" | tr -d '\r')"
  if [[ -z "${bad_images}" ]]; then
    pass "CA2: todas las imágenes tienen tag explícito y ninguna usa :latest"
  else
    fail "CA2: imágenes sin tag o con :latest -> ${bad_images//$'\n'/, }"
  fi

  if grep -nE ':latest([^A-Za-z0-9_.-]|$)' "${compose_file}" >/dev/null; then
    fail "CA2: el archivo contiene la cadena ':latest'"
  else
    pass "CA2: el archivo fuente no contiene ':latest'"
  fi

  # 4. CA2 — imágenes propias: ${REGISTRY_URL}/circleguard/<servicio>:${IMAGE_TAG} SemVer
  own_ok=true
  for svc in "${OWN_SERVICES[@]}"; do
    image="$(jqx -r --arg s "${svc}" '.services[$s].image // ""' <"${json_file}" | tr -d '\r')"
    expected="${REGISTRY_URL}/circleguard/${svc}:${IMAGE_TAG}"
    if [[ "${image}" != "${expected}" ]]; then
      own_ok=false
      fail "CA2: ${svc} resuelve a '${image}', se esperaba '${expected}'"
    elif [[ ! "${image##*:}" =~ ${SEMVER_REGEX} ]]; then
      own_ok=false
      fail "CA2: ${svc} usa tag no SemVer '${image##*:}'"
    fi
  done
  ${own_ok} && pass "CA2: las 6 imágenes propias resuelven a ${REGISTRY_URL}/circleguard/<servicio>:${IMAGE_TAG}"

  # 5. CA2 — sin IMAGE_TAG ni APP_VERSION compose debe negarse (no hay fallback a latest)
  no_tag_env="${TMP_DIR}/.env.${env_name}.notag"
  grep -vE '^(IMAGE_TAG|APP_VERSION)=' "${env_file}" >"${no_tag_env}"
  if env -u IMAGE_TAG -u APP_VERSION docker compose --env-file "${no_tag_env}" -f "${compose_file}" config -q >/dev/null 2>&1; then
    fail "CA2: compose renderiza sin IMAGE_TAG/APP_VERSION (podría resolver a un tag ambiguo)"
  else
    pass "CA2: sin IMAGE_TAG/APP_VERSION compose falla de forma explícita"
  fi

  # 6. CA3 — healthcheck funcional en todos los contenedores
  no_hc="$(jqx -r '.services | to_entries[]
      | select((.value.healthcheck == null) or (.value.healthcheck.disable == true)
               or ((.value.healthcheck.test // []) | length) == 0
               or ((.value.healthcheck.test // [])[0] == "NONE"))
      | .key' <"${json_file}" | tr -d '\r')"
  total="$(jqx -r '.services | length' <"${json_file}" | tr -d '\r')"
  if [[ -z "${no_hc}" ]]; then
    pass "CA3: los ${total} contenedores declaran healthcheck activo"
  else
    fail "CA3: contenedores sin healthcheck: ${no_hc//$'\n'/, }"
  fi

  # 7. CA3 — depends_on siempre con condition: service_healthy
  bad_deps="$(jqx -r '.services | to_entries[] | .key as $s
      | (.value.depends_on // {}) | to_entries[]
      | select(.value.condition != "service_healthy") | "\($s)->\(.key)"' <"${json_file}" | tr -d '\r')"
  n_deps="$(jqx -r '[.services[] | (.depends_on // {}) | keys[]] | length' <"${json_file}" | tr -d '\r')"
  if [[ -z "${bad_deps}" ]]; then
    pass "CA3: ${n_deps} dependencias depends_on, todas con condition: service_healthy"
  else
    fail "CA3: depends_on sin service_healthy: ${bad_deps//$'\n'/, }"
  fi

  # 8. CA3 — orden de arranque esperado
  expect_dep() {
    local svc="$1"; shift
    local dep
    for dep in "$@"; do
      if [[ "$(jqx -r --arg s "${svc}" --arg d "${dep}" '.services[$s].depends_on[$d].condition // ""' <"${json_file}" | tr -d '\r')" != "service_healthy" ]]; then
        fail "CA3: ${svc} debe esperar a ${dep} (service_healthy)"
        return
      fi
    done
    pass "CA3: ${svc} espera a: $*"
  }
  expect_dep kafka zookeeper
  expect_dep identity-service postgres kafka
  expect_dep auth-service postgres openldap identity-service
  expect_dep promotion-service postgres neo4j kafka redis
  expect_dep form-service postgres kafka
  expect_dep gateway-service redis
  expect_dep web-client auth-service identity-service promotion-service form-service gateway-service

  # 9. Sin container_name (evita colisiones entre ambientes en un mismo nodo)
  named="$(jqx -r '.services | to_entries[] | select(.value.container_name != null) | .key' <"${json_file}" | tr -d '\r')"
  if [[ -z "${named}" ]]; then
    pass "Aislamiento: ningún servicio fija container_name (proyecto $(jqx -r '.name' <"${json_file}" | tr -d '\r'))"
  else
    fail "Aislamiento: servicios con container_name fijo: ${named//$'\n'/, }"
  fi

  # 10. stage/prod: middleware sin puertos en el host y secretos obligatorios
  if [[ "${env_name}" != "dev" ]]; then
    exposed="$(jqx -r --argjson mw "$(printf '%s\n' "${MIDDLEWARE[@]}" | jqx -R . | jqx -s -c .)" \
        '.services | to_entries[] | select(.key as $k | $mw | index($k)) | select((.value.ports // []) | length > 0) | .key' \
        <"${json_file}" | tr -d '\r')"
    if [[ -z "${exposed}" ]]; then
      pass "Hardening: el middleware no publica puertos en el host"
    else
      fail "Hardening: middleware con puertos publicados: ${exposed//$'\n'/, }"
    fi
    no_secret_env="${TMP_DIR}/.env.${env_name}.nosecret"
    grep -vE '^POSTGRES_PASSWORD=' "${env_file}" >"${no_secret_env}"
    if env -u POSTGRES_PASSWORD docker compose --env-file "${no_secret_env}" -f "${compose_file}" config -q >/dev/null 2>&1; then
      fail "Hardening: compose renderiza sin POSTGRES_PASSWORD"
    else
      pass "Hardening: sin POSTGRES_PASSWORD compose falla de forma explícita"
    fi
  fi
done

echo
if [[ ${failures} -eq 0 ]]; then
  echo "=== RESULTADO: OK — ${checks} verificaciones superadas en: ${ENVS[*]} ==="
else
  echo "=== RESULTADO: FALLÓ — ${failures} de ${checks} verificaciones fallaron ===" >&2
  exit 1
fi
