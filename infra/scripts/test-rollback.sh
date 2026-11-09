#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Pruebas automatizadas de rollback.sh (US-14 / CA2)
# Usa un "docker" simulado para validar la lógica sin un ambiente real.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLBACK="${SCRIPT_DIR}/rollback.sh"
WORK="$(mktemp -d -t cg-rollback-test-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

# docker simulado: registra la llamada y responde como compose según DOCKER_STUB_MODE.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "IMAGE_TAG=${IMAGE_TAG:-} $*" >> "${DOCKER_LOG}"
if [[ " $* " == *" up "* && "${DOCKER_STUB_MODE:-ok}" == "unhealthy" ]]; then exit 1; fi
if [[ " $* " == *" ps "* && " $* " == *"{{.Image}}"* ]]; then
  echo "auth-service registry:5000/circleguard/auth-service:${IMAGE_TAG}"
  echo "postgres postgres:16.4-alpine"
fi
exit 0
STUB
chmod +x "${WORK}/bin/docker"
export PATH="${WORK}/bin:${PATH}"
export DOCKER_LOG="${WORK}/docker.log"
export ROLLBACK_STATE_DIR="${WORK}/state"
export ENV_FILE="${WORK}/.env"
export REGISTRY_URL="registry:5000"
touch "${ENV_FILE}" "${DOCKER_LOG}"

pass() { echo "[OK] $*"; }
die()  { echo "[FALLO] $*" >&2; exit 1; }
state() { cat "${ROLLBACK_STATE_DIR}/$1/$2"; }

# Caso 1: sin versión estable registrada -> código 2.
set +e; "${ROLLBACK}" rollback stage >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 2 ]] || die "Caso 1: se esperaba código 2, obtenido ${rc}"
pass "Caso 1: sin versión estable el rollback se rechaza (código 2)"

# Caso 2: 1.0.0 estable, 1.1.0 desplegada y falla -> vuelve a 1.0.0.
"${ROLLBACK}" mark-stable stage 1.0.0 >/dev/null
"${ROLLBACK}" mark-deployed stage 1.1.0 >/dev/null
"${ROLLBACK}" rollback stage >/dev/null
[[ "$(state stage current_version)" == "1.0.0" ]] || die "Caso 2: current_version debería ser 1.0.0"
grep -q "IMAGE_TAG=1.0.0 compose .* pull" "${DOCKER_LOG}" || die "Caso 2: no descargó las imágenes 1.0.0"
grep -q "IMAGE_TAG=1.0.0 compose .* up -d" "${DOCKER_LOG}" || die "Caso 2: no redesplegó con IMAGE_TAG=1.0.0"
pass "Caso 2: despliegue fallido de 1.1.0 restaura la última estable 1.0.0"

# Caso 3: la versión actual ya es estable (1.2.0) -> vuelve a la estable anterior (1.0.0).
"${ROLLBACK}" mark-stable stage 1.2.0 >/dev/null
"${ROLLBACK}" rollback stage >/dev/null
[[ "$(state stage current_version)" == "1.0.0" ]] || die "Caso 3: debería volver a 1.0.0"
pass "Caso 3: sin despliegue fallido, vuelve a la versión estable anterior"

# Caso 4: ROLLBACK_TARGET_VERSION explícita (--to).
"${ROLLBACK}" rollback stage --to 1.2.0 >/dev/null
[[ "$(state stage current_version)" == "1.2.0" ]] || die "Caso 4: debería quedar en 1.2.0"
pass "Caso 4: --to restaura exactamente la versión solicitada"

# Caso 5: versiones inválidas o 'latest' se rechazan sin tocar la pila.
for bad in latest 1.2 v1.0.0 abc; do
  set +e; "${ROLLBACK}" rollback stage --to "${bad}" >/dev/null 2>&1; rc=$?; set -e
  [[ ${rc} -eq 1 ]] || die "Caso 5: '${bad}' debería rechazarse (código 1), obtenido ${rc}"
done
pass "Caso 5: 'latest' y versiones no SemVer se rechazan"

# Caso 6: la pila restaurada no queda saludable -> código 3 y no se marca estable.
"${ROLLBACK}" mark-deployed stage 1.3.0 >/dev/null
set +e; DOCKER_STUB_MODE=unhealthy "${ROLLBACK}" rollback stage >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 3 ]] || die "Caso 6: se esperaba código 3, obtenido ${rc}"
[[ "$(state stage current_version)" == "1.3.0" ]] || die "Caso 6: no debe registrar la versión fallida como actual"
grep -q "rollback-failed" "${ROLLBACK_STATE_DIR}/stage/history.tsv" || die "Caso 6: falta el registro rollback-failed"
pass "Caso 6: si el rollback no queda saludable, falla con código 3 y queda en el historial"

# Caso 7: dev no hace pull (las imágenes se construyen localmente).
: > "${DOCKER_LOG}"
"${ROLLBACK}" mark-stable dev 2.0.0 >/dev/null
"${ROLLBACK}" mark-deployed dev 2.1.0 >/dev/null
"${ROLLBACK}" rollback dev >/dev/null
! grep -q " pull" "${DOCKER_LOG}" || die "Caso 7: dev no debería ejecutar pull"
pass "Caso 7: en dev el rollback reutiliza imágenes locales (sin pull)"

# Caso 8: ambiente inválido.
set +e; "${ROLLBACK}" rollback qa >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 1 ]] || die "Caso 8: ambiente inválido debería dar código 1"
pass "Caso 8: ambiente inválido rechazado"

# Caso 9: modo remoto (--host) reutiliza environment.sh de US-13 con deploy + verify.
cat > "${WORK}/environment.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${ENV_SCRIPT_LOG}"
if [[ "$1" == "verify" && "${ENV_STUB_MODE:-ok}" == "unhealthy" ]]; then exit 1; fi
exit 0
STUB
export ENVIRONMENT_SCRIPT="${WORK}/environment.sh" ENV_SCRIPT_LOG="${WORK}/env.log"
: > "${ENV_SCRIPT_LOG}"
"${ROLLBACK}" mark-stable prod 3.0.0 >/dev/null
"${ROLLBACK}" mark-deployed prod 3.1.0 >/dev/null
( cd "${WORK}" && "${ROLLBACK}" rollback prod --host 10.0.0.5 >/dev/null )
grep -q "^deploy --env prod --version 3.0.0 --host 10.0.0.5" "${ENV_SCRIPT_LOG}" || die "Caso 9: no redesplegó 3.0.0 por SSH"
grep -q "^verify --env prod --version 3.0.0 --host 10.0.0.5" "${ENV_SCRIPT_LOG}" || die "Caso 9: no verificó la salud tras el rollback"
[[ "$(state prod current_version)" == "3.0.0" ]] || die "Caso 9: current_version debería ser 3.0.0"
pass "Caso 9: con --host restaura 3.0.0 en el nodo remoto (deploy + verify de US-13)"

# Caso 10: en modo remoto, si la verificación falla -> código 3.
"${ROLLBACK}" mark-deployed prod 3.2.0 >/dev/null
set +e; ( cd "${WORK}" && ENV_STUB_MODE=unhealthy "${ROLLBACK}" rollback prod --host 10.0.0.5 >/dev/null 2>&1 ); rc=$?; set -e
[[ ${rc} -eq 3 ]] || die "Caso 10: se esperaba código 3, obtenido ${rc}"
pass "Caso 10: verificación remota fallida tras el rollback devuelve código 3"

echo "Todas las pruebas de rollback.sh pasaron."
