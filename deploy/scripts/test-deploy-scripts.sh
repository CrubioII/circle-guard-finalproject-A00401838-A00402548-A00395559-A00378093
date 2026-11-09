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

echo "[1/5] Sintaxis"
for f in deploy-env.sh verify-env-health.sh environment.sh run-e2e.sh; do
  if bash -n "${S}/${f}"; then ok "bash -n ${f}"; else ko "bash -n ${f}"; fi
done

echo "[2/5] deploy-env.sh rechaza entradas inválidas"
touch "${TMP}/.env" "${TMP}/compose.yml"
expect_fail "ambiente inválido 'qa'"            env IMAGE_TAG=1.0.0 ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" qa
expect_fail "IMAGE_TAG=latest"                 env IMAGE_TAG=latest ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail "IMAGE_TAG vacío"                  env IMAGE_TAG= ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail "IMAGE_TAG no SemVer (1.2)"        env IMAGE_TAG=1.2 ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail ".env del ambiente inexistente"    env IMAGE_TAG=1.0.0 ENV_FILE="${TMP}/missing.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev
expect_fail "STDIN de contraseña sin usuario"  env IMAGE_TAG=1.0.0 REGISTRY_PASSWORD_STDIN=1 ENV_FILE="${TMP}/.env" COMPOSE_FILE="${TMP}/compose.yml" bash "${S}/deploy-env.sh" dev

echo "[3/5] environment.sh valida y arma los comandos remotos"
expect_fail "acción inválida"                  bash "${S}/environment.sh" rollout --env dev --version 1.0.0 --host h
expect_fail "--env inválido"                   bash "${S}/environment.sh" deploy --env qa --version 1.0.0 --host h
expect_fail "--version latest"                 bash "${S}/environment.sh" deploy --env dev --version latest --host h
expect_fail "--host obligatorio"               bash "${S}/environment.sh" deploy --env dev --version 1.0.0

secret="Sup3r-S3cret-\$(id)"
out="$(SSH_KEY=/keys/id SSH_USER=ec2-user REGISTRY_USER=ci-bot REGISTRY_PASSWORD="${secret}" REGISTRY_URL=52.14.6.11:5000 \
      bash "${S}/environment.sh" deploy --env dev --version 1.4.0 --host 52.15.213.209 --dry-run 2>&1)"
expect_in "crea el directorio remoto de la pila"     "mkdir -p /opt/circleguard/dev/compose/stack" "${out}"
expect_in "copia compose + scripts por SCP"           "docker-compose.dev.yml" "${out}"
expect_in "copia deploy-env.sh y verify-env-health.sh" "verify-env-health.sh ec2-user@52.15.213.209:/opt/circleguard/dev/compose/stack/" "${out}"
expect_in "usa la llave SSH inyectada"                "-i /keys/id" "${out}"
expect_in "fija la versión SemVer remota"             "IMAGE_TAG=1.4.0" "${out}"
expect_in "contraseña por stdin (flag)"               "REGISTRY_PASSWORD_STDIN=1" "${out}"
expect_in "usuario del registro"                      "REGISTRY_USER=ci-bot" "${out}"
if [[ "${out}" == *"${secret}"* || "${out}" == *"Sup3r-S3cret"* ]]; then ko "la contraseña NO aparece en los comandos"; else ok "la contraseña NO aparece en los comandos"; fi

out="$(SSH_USER=ec2-user bash "${S}/environment.sh" deploy --env stage --version 1.4.0 --host 3.17.163.44 --dry-run 2>&1)"
expect_in "stage usa su propio directorio"            "/opt/circleguard/stage/compose/stack" "${out}"
expect_in "stage usa su compose"                      "docker-compose.stage.yml" "${out}"
expect_in "sin credenciales no hay login"             "REGISTRY_PASSWORD_STDIN=0" "${out}"

out="$(SSH_USER=ec2-user bash "${S}/environment.sh" verify --env dev --version 1.4.0 --host 52.15.213.209 --dry-run 2>&1)"
expect_in "verify ejecuta verify-env-health.sh remoto" "/opt/circleguard/dev/compose/stack/verify-env-health.sh dev" "${out}"

echo "[4/5] run-e2e.sh valida argumentos"
expect_fail "run-e2e --env inválido"           bash "${S}/run-e2e.sh" --env qa --local
expect_fail "run-e2e requiere --host"          bash "${S}/run-e2e.sh" --env dev

echo "[5/5] Puertos del runner E2E == puertos publicados por compose"
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

echo
if [[ ${fail} -eq 0 ]]; then
  echo "=== RESULTADO: OK — ${pass} pruebas superadas ==="
else
  echo "=== RESULTADO: FALLÓ — ${fail} de $((pass + fail)) pruebas fallaron ===" >&2
  exit 1
fi
