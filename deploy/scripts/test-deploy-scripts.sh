#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Pruebas de los scripts de despliegue y promoción (US-13)
#
# No requiere Docker, red ni credenciales reales: valida sintaxis, rechazo de entradas
# inválidas (ambiente, SemVer/latest, host), los comandos SSH/SCP generados (--dry-run),
# que la contraseña del registro NUNCA aparezca en argumentos, y que los puertos del
# runner E2E coincidan con los publicados por deploy/compose/docker-compose.<env>.yml.
#
# Uso: bash deploy/scripts/test-deploy-scripts.sh
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="${ROOT_DIR}/deploy/scripts"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  [PASS] %s\n' "$*"; }
ko()  { fail=$((fail + 1)); printf '  [FAIL] %s\n' "$*"; }
expect_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ko "${d}"; else ok "${d}"; fi; }
expect_in()   { local d="$1" needle="$2" hay="$3"; if [[ "${hay}" == *"${needle}"* ]]; then ok "${d}"; else ko "${d} (no contiene: ${needle})"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
echo "=== US-13: pruebas de deploy/scripts ==="

echo "[1/6] Sintaxis"
for f in deploy-env.sh verify-env-health.sh environment.sh run-e2e.sh; do
  if bash -n "${S}/${f}"; then ok "bash -n ${f}"; else ko "bash -n ${f}"; fi
done

echo "[2/6] deploy-env.sh rechaza entradas inválidas"
touch "${TMP}/.env" "${TMP}/compose.yml"
expect_fail "ambiente inválido 'qa'"            env IMAGE_TAG=1.0.0 ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" qa
expect_fail "IMAGE_TAG=latest"                 env IMAGE_TAG=latest ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail "IMAGE_TAG vacío"                  env IMAGE_TAG= ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail "IMAGE_TAG no SemVer (1.2)"        env IMAGE_TAG=1.2 ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail ".env del ambiente inexistente"    env IMAGE_TAG=1.0.0 ENV_FILE="${TMP}/missing.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail "STDIN de contraseña sin usuario"  env IMAGE_TAG=1.0.0 REGISTRY_PASSWORD_STDIN=1 ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev

echo "[3/6] environment.sh valida y arma los comandos remotos"
expect_fail "acción inválida"                  bash "${S}/environment.sh" rollout --env dev --version 1.0.0 --host h
expect_fail "--env inválido"                   bash "${S}/environment.sh" deploy --env qa --version 1.0.0 --host h
expect_fail "--version latest"                 bash "${S}/environment.sh" deploy --env dev --version latest --host h
expect_fail "--host obligatorio"               bash "${S}/environment.sh" deploy --env dev --version 1.0.0

secret="Sup3r-S3cret-\$(id)"
out="$(SSH_KEY=/keys/id SSH_USER=ec2-user REGISTRY_USER=ci-bot REGISTRY_PASSWORD="${secret}" REGISTRY_URL=18.117.90.15:5000 \
      bash "${S}/environment.sh" deploy --env dev --version 1.4.0 --host 52.15.165.116 --dry-run 2>&1)"
expect_in "crea el directorio remoto de la pila"     "mkdir -p /opt/circleguard/dev/compose/stack" "${out}"
expect_in "copia compose + scripts por SCP"           "docker-compose.dev.yml" "${out}"
expect_in "copia deploy-env.sh y verify-env-health.sh" "verify-env-health.sh ec2-user@52.15.165.116:/opt/circleguard/dev/compose/stack/" "${out}"
expect_in "usa la llave SSH inyectada"                "-i /keys/id" "${out}"
expect_in "fija la versión SemVer remota"             "IMAGE_TAG=1.4.0" "${out}"
expect_in "contraseña por stdin (flag)"               "REGISTRY_PASSWORD_STDIN=1" "${out}"
expect_in "usuario del registro"                      "REGISTRY_USER=ci-bot" "${out}"
if [[ "${out}" == *"${secret}"* || "${out}" == *"Sup3r-S3cret"* ]]; then ko "la contraseña NO aparece en los comandos"; else ok "la contraseña NO aparece en los comandos"; fi

out="$(SSH_USER=ec2-user bash "${S}/environment.sh" deploy --env stage --version 1.4.0 --host 52.14.89.125 --dry-run 2>&1)"
expect_in "stage usa su propio directorio"            "/opt/circleguard/stage/compose/stack" "${out}"
expect_in "stage usa su compose"                      "docker-compose.stage.yml" "${out}"
expect_in "sin credenciales no hay login"             "REGISTRY_PASSWORD_STDIN=0" "${out}"

out="$(SSH_USER=ec2-user bash "${S}/environment.sh" verify --env dev --version 1.4.0 --host 52.15.165.116 --dry-run 2>&1)"
expect_in "verify ejecuta verify-env-health.sh remoto" "/opt/circleguard/dev/compose/stack/verify-env-health.sh dev" "${out}"

echo "[4/6] run-e2e.sh valida argumentos"
expect_fail "run-e2e --env inválido"           bash "${S}/run-e2e.sh" --env qa --local
expect_fail "run-e2e requiere --host"          bash "${S}/run-e2e.sh" --env dev
# US-22: el agente de Jenkins puede no tener kubectl; --k8s usa el binario fijo de lib.sh.
src="$(cat "${S}/run-e2e.sh")"
expect_in "run-e2e --k8s descarga kubectl si falta"     'ensure_tool kubectl' "${src}"
expect_in "run-e2e --k8s usa ese kubectl en port-forward" '"${KUBECTL}" -n "${namespace}" port-forward' "${src}"

echo "[5/6] Puertos del runner E2E == puertos publicados por compose"
for pair in dev:0 stage:1000 prod:2000; do
  env_name="${pair%%:*}"; offset="${pair##*:}"
  compose="${ROOT_DIR}/deploy/compose/docker-compose.${env_name}.yml"
  all_ok=true
  for svc_port in AUTH:8180 IDENTITY:8083 PROMOTION:8088 FORM:8086 GATEWAY:8087; do
    svc="${svc_port%%:*}"; base="${svc_port##*:}"
    grep -q "\${${svc}_SERVICE_PORT:-$((base + offset))}" "${compose}" || { all_ok=false; ko "${env_name}: ${svc}_SERVICE_PORT != $((base + offset))"; }
  done
  grep -q "\${WEB_CLIENT_PORT:-$((8080 + offset))}" "${compose}" || { all_ok=false; ko "${env_name}: WEB_CLIENT_PORT != $((8080 + offset))"; }
  ${all_ok} && ok "${env_name}: puertos del túnel E2E coinciden con docker-compose.${env_name}.yml (offset +${offset})"
done

echo "[6/6] health-report-to-junit.sh: salud post-despliegue visible en Jenkins (US-31)"
J="${S}/health-report-to-junit.sh"
if bash -n "${J}"; then ok "bash -n health-report-to-junit.sh"; else ko "bash -n health-report-to-junit.sh"; fi
cat >"${TMP}/pass.json" <<'EOF'
{"env":"prod","expectedTag":"1.4.0","status":"PASS","failures":0,"checkedAt":"2026-11-09T10:00:00Z","host":"node-prod","services":[{"service":"postgres","health":"healthy","image":"postgres:16.4-alpine","probe":"n/a","ok":true,"reason":""},{"service":"auth-service","health":"healthy","image":"r/circleguard/auth-service:1.4.0","probe":"readiness UP","ok":true,"reason":""}]}
EOF
cat >"${TMP}/fail.json" <<'EOF'
{"env":"prod","expectedTag":"1.4.0","status":"FAIL","failures":1,"checkedAt":"2026-11-09T10:00:00Z","host":"node-prod","services":[{"service":"auth-service","health":"healthy","image":"r/circleguard/auth-service:1.4.0","probe":"readiness UP","ok":true,"reason":""},{"service":"gateway-service","health":"unhealthy","image":"r/circleguard/gateway-service:1.4.0","probe":"readiness FAIL","ok":false,"reason":"readiness != UP & <timeout>"}]}
EOF
printf '{"env":"prod","expectedTag":"1.4.0","status":"FAIL","failures":-1,"reason":"sin respuesta del nodo (exit 255)"}\n' >"${TMP}/noreply.json"

if bash "${J}" "${TMP}/pass.json" "${TMP}/pass.xml" 2>/dev/null; then
  x="$(cat "${TMP}/pass.xml")"
  expect_in "JUnit: un caso por contenedor"        'tests="2" failures="0"' "${x}"
  expect_in "JUnit: classname por ambiente"        'classname="circleguard.prod.health" name="auth-service"' "${x}"
  expect_in "JUnit: versión esperada como propiedad" 'name="expectedTag" value="1.4.0"' "${x}"
else ko "conversión de un reporte PASS"; fi
if bash "${J}" "${TMP}/fail.json" "${TMP}/fail.xml" 2>/dev/null; then
  x="$(cat "${TMP}/fail.xml")"
  expect_in "JUnit: contenedor no sano = <failure>" '<testcase classname="circleguard.prod.health" name="gateway-service"><failure' "${x}"
  expect_in "JUnit: cuenta de fallos"              'failures="1"' "${x}"
  expect_in "JUnit: escapa caracteres XML del motivo" 'readiness != UP &amp; &lt;timeout&gt;' "${x}"
else ko "conversión de un reporte FAIL"; fi
if bash "${J}" "${TMP}/noreply.json" "${TMP}/noreply.xml" 2>/dev/null; then
  expect_in "JUnit: nodo sin respuesta = caso fallido con motivo" 'sin respuesta del nodo (exit 255)' "$(cat "${TMP}/noreply.xml")"
else ko "conversión de un reporte sin servicios"; fi
expect_fail "JUnit: rechaza un reporte inexistente"  bash "${J}" "${TMP}/missing.json" "${TMP}/x.xml"

# US-22: reporte de 'k8s-deploy.sh verify --report' (sin "services").
cat >"${TMP}/k8s-ok.json" <<'EOF'
{"env":"prod","namespace":"circleguard-prod","version":"0.5.0","platform":"k8s","ready":["deployment.apps/auth-service","statefulset.apps/postgres"],"notReady":[],"wrongImages":[],"healthy":true}
EOF
cat >"${TMP}/k8s-fail.json" <<'EOF'
{"env":"stage","namespace":"circleguard-stage","version":"0.5.0","platform":"k8s","ready":["deployment.apps/auth-service"],"notReady":["deployment.apps/form-service"],"wrongImages":["gateway-service=r/circleguard/gateway-service:0.4.1"],"healthy":false}
EOF
if bash "${J}" "${TMP}/k8s-ok.json" "${TMP}/k8s-ok.xml" 2>/dev/null; then
  x="$(cat "${TMP}/k8s-ok.xml")"
  expect_in "JUnit k8s: un caso por recurso listo, sin fallos"   'tests="2" failures="0"' "${x}"
  expect_in "JUnit k8s: nombre del recurso como caso"            'name="statefulset.apps/postgres"' "${x}"
  expect_in "JUnit k8s: versión desplegada como propiedad"       'name="expectedTag" value="0.5.0"' "${x}"
else ko "conversión de un reporte k8s sano"; fi
if bash "${J}" "${TMP}/k8s-fail.json" "${TMP}/k8s-fail.xml" 2>/dev/null; then
  x="$(cat "${TMP}/k8s-fail.xml")"
  expect_in "JUnit k8s: no listo e imagen con otra versión fallan" 'tests="3" failures="2"' "${x}"
  expect_in "JUnit k8s: rollout incompleto como <failure>"         'name="deployment.apps/form-service"><failure message="rollout incompleto"' "${x}"
  expect_in "JUnit k8s: imagen con otra versión"                   'image=r/circleguard/gateway-service:0.4.1' "${x}"
else ko "conversión de un reporte k8s con fallos"; fi

echo
if [[ ${fail} -eq 0 ]]; then
  echo "=== RESULTADO: OK — ${pass} pruebas superadas ==="
else
  echo "=== RESULTADO: FALLÓ — ${fail} de $((pass + fail)) pruebas fallaron ===" >&2
  exit 1
fi
