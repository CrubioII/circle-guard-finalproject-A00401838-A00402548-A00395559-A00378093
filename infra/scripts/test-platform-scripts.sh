#!/usr/bin/env bash
# =============================================================================
# Pruebas sin AWS de los scripts de plataforma:
#   infra/terraform/scripts/tf-pipeline.sh (US-22)
# Usa un terraform simulado que registra sus argumentos.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d -t cg-platform-test-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
die()  { echo "  [FAIL] $*" >&2; exit 1; }

mkdir -p "${WORK}/bin"
# terraform simulado: plan devuelve 2 (con cambios) y escribe el plan; show imprime JSON mínimo.
cat > "${WORK}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $*" >> "${STUB_LOG}"
for a in "$@"; do case "$a" in -out=*) : > "${a#-out=}"; echo plan > "${a#-out=}" ;; esac; done
case " $* " in
  *" plan "*) echo "Plan: 1 to add"; exit 2 ;;
  *" show -json "*) echo '{"resource_changes":[{"address":"module.storage.aws_s3_bucket.this","change":{"actions":["create"]}}]}' ;;
  *" show "*) echo "# module.storage.aws_s3_bucket.this will be created" ;;
esac
exit 0
STUB
chmod +x "${WORK}/bin/"*
export PATH="${WORK}/bin:${PATH}" STUB_LOG="${WORK}/calls.log"
: > "${STUB_LOG}"

echo "== tf-pipeline.sh (US-22)"
export REPORT_DIR="${WORK}/tf" TF_STATE_BUCKET="bucket-prueba"
bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" plan --env stage >/dev/null
grep -q -- "-backend-config=bucket=bucket-prueba" "${STUB_LOG}" || die "init no usa TF_STATE_BUCKET"
grep -q -- "-backend-config=key=envs/stage/platform.tfstate" "${STUB_LOG}" || die "la key del estado no es la de stage"
grep -q -- "-backend-config=dynamodb_table=circleguard-terraform-locks" "${STUB_LOG}" || die "falta la tabla de bloqueo"
grep -q -- "plan -no-color -lock-timeout=5m -detailed-exitcode -out=${WORK}/tf/stage.tfplan" "${STUB_LOG}" || die "plan no guarda stage.tfplan"
[[ -s "${WORK}/tf/stage-plan.txt" && -s "${WORK}/tf/stage-plan.json" ]] || die "faltan los reportes del plan"
if command -v jq >/dev/null 2>&1; then
  jq -e '.hasChanges == true and (.create | length) == 1' "${WORK}/tf/stage-summary.json" >/dev/null || die "resumen del plan incorrecto"
fi
pass "plan: backend S3 + DynamoDB por ambiente, plan guardado y reportes txt/json (exit 2 = con cambios no falla)"

bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" apply --env stage >/dev/null
grep -q -- "apply -no-color -lock-timeout=5m -auto-approve ${WORK}/tf/stage.tfplan" "${STUB_LOG}" || die "apply no usa el plan guardado"
pass "apply: aplica exactamente el plan guardado"

set +e; bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" apply --env prod >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 3 ]] || die "apply sin plan previo debería salir con 3 (obtuvo ${rc})"
set +e; bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" plan --env qa >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 1 ]] || die "ambiente inválido debería salir con 1"
pass "apply sin plan revisado se rechaza (3) y un ambiente inválido también (1)"

echo "=== RESULTADO: OK — ${PASS} pruebas de plataforma superadas ==="
