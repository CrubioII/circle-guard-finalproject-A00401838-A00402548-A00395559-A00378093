#!/usr/bin/env bash
# =============================================================================
# Prueba de bloqueo del estado remoto de Terraform (US-36, CA2)
#
# Uso:
#   bash infra/terraform/scripts/test-state-lock.sh --profile circleguard-terraform
#
# Opciones:
#   --profile <p>   perfil del AWS CLI (si no, AWS_PROFILE o la cadena estándar)
#   --region <r>    región del bucket (por defecto: us-east-2)
#   --hold <seg>    segundos que la ejecución A mantiene el bloqueo (por defecto: 45)
#   --keep-state    no borra el estado de prueba al terminar
#
# Simula a dos personas con copias separadas de tests/state-lock que apuntan al
# mismo estado (s3://<bucket>/tests/state-lock/terraform.tfstate):
#   1. A ejecuta apply y mantiene el bloqueo unos segundos.
#   2. Mientras A trabaja, B intenta apply y plan: los dos deben fallar con
#      "Error acquiring the state lock" y el estado no cambia.
#   3. A termina, el archivo .tflock desaparece y B aplica sin problemas.
#   4. Se destruye la prueba y se borran todas las versiones de su estado.
# No crea recursos en AWS además de los objetos de estado de prueba.
# Reporte: reports/terraform/state-lock-test.txt
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backend-lib.sh"

HOLD=45
KEEP_STATE=false
KEY="tests/state-lock/terraform.tfstate"

usage() { sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) [[ $# -ge 2 ]] || fail "--profile necesita un valor."; use_profile "$2"; shift ;;
        --region) [[ $# -ge 2 ]] || fail "--region necesita un valor."; AWS_REGION="$2"; shift ;;
        --hold)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 20 ]] || fail "--hold necesita un número de segundos (mínimo 20)."
            HOLD="$2"; shift ;;
        --keep-state) KEEP_STATE=true ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done

require_tools
export TF_IN_AUTOMATION=1
export AWS_REGION
ACCOUNT="$(account_id)"
BUCKET="$(state_bucket "${ACCOUNT}")"
LOCK_KEY="${KEY}.tflock"
bucket_exists "${BUCKET}" || fail "No existe el bucket ${BUCKET}. Ejecuta primero bootstrap-backend.sh."

mkdir -p "${REPORT_DIR}"
REPORT="${REPORT_DIR}/state-lock-test.txt"
WORK="$(mktemp -d)"
A_PID=""
cleanup() {
    [[ -z "${A_PID}" ]] || kill "${A_PID}" 2>/dev/null || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

# Toda la salida va también al reporte.
exec > >(tee "${REPORT}") 2>&1

log "Prueba de bloqueo sobre s3://${BUCKET}/${KEY} ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))."
object_exists "${BUCKET}" "${KEY}" && fail "Ya existe ${KEY}: puede haber otra prueba en curso. Bórralo antes de repetir."

export TF_PLUGIN_CACHE_DIR="${WORK}/plugin-cache"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"
for who in A B; do
    mkdir -p "${WORK}/${who}"
    cp "${TF_ROOT}/tests/state-lock/main.tf" "${WORK}/${who}/"
    cat > "${WORK}/${who}/backend.hcl" <<EOF
bucket       = "${BUCKET}"
key          = "${KEY}"
region       = "${AWS_REGION}"
use_lockfile = true
encrypt      = true
EOF
    terraform -chdir="${WORK}/${who}" init -backend-config=backend.hcl -input=false -no-color >/dev/null
done
ok "Dos copias independientes (A y B) inicializadas contra el mismo estado."

FAILURES=0
check() {
    if eval "$2"; then ok "$1"; else printf '[backend][FALLA] %s\n' "$1"; FAILURES=$((FAILURES + 1)); fi
}

# 1. A toma el bloqueo -----------------------------------------------------------
log "A: terraform apply (mantiene el bloqueo ${HOLD} s)..."
terraform -chdir="${WORK}/A" apply -auto-approve -input=false -lock-timeout=0s -no-color \
    -var run_label=A -var hold_seconds="${HOLD}" > "${WORK}/a-apply.log" 2>&1 &
A_PID=$!

for _ in $(seq 1 60); do
    object_exists "${BUCKET}" "${LOCK_KEY}" && break
    kill -0 "${A_PID}" 2>/dev/null || break
    sleep 1
done
check "Mientras A aplica existe el bloqueo s3://${BUCKET}/${LOCK_KEY}." 'object_exists "${BUCKET}" "${LOCK_KEY}"'
LOCK_INFO="$(aws_cli s3 cp "s3://${BUCKET}/${LOCK_KEY}" - 2>/dev/null | tr -d '\r' || true)"
# Se muestra la operación y el ID del bloqueo; "Who" (usuario@equipo) se omite.
printf '        Contenido del bloqueo: %s\n' "$(printf '%s' "${LOCK_INFO}" | sed -E 's/"Who":"[^"]*"/"Who":"<omitido>"/')"

# 2. B intenta aplicar y planear mientras A tiene el bloqueo ---------------------
log "B: terraform apply sobre el mismo estado mientras A trabaja..."
set +e
terraform -chdir="${WORK}/B" apply -auto-approve -input=false -lock-timeout=0s -no-color \
    -var run_label=B -var hold_seconds=20 > "${WORK}/b-apply-blocked.log" 2>&1
B_APPLY_RC=$?
terraform -chdir="${WORK}/B" plan -input=false -lock-timeout=10s -no-color \
    -var run_label=B -var hold_seconds=20 > "${WORK}/b-plan-blocked.log" 2>&1
B_PLAN_RC=$?
set -e
check "El apply de B falla (código ${B_APPLY_RC})." '[[ ${B_APPLY_RC} -ne 0 ]]'
check "El apply de B informa 'Error acquiring the state lock'." 'grep -q "Error acquiring the state lock" "${WORK}/b-apply-blocked.log"'
check "El plan de B espera 10 s y también falla por el bloqueo (código ${B_PLAN_RC})." '[[ ${B_PLAN_RC} -ne 0 ]] && grep -q "Error acquiring the state lock" "${WORK}/b-plan-blocked.log"'
printf '        Mensaje que recibe B:\n'
grep -E "Error acquiring the state lock|Operation:|Path:|Created:" "${WORK}/b-apply-blocked.log" \
    | sed -E 's/^[│| ]*//; s/^/          /' | head -6

# 3. A termina y libera el bloqueo ------------------------------------------------
log "Esperando a que A termine..."
set +e
wait "${A_PID}"
A_RC=$?
set -e
A_PID=""
check "El apply de A termina bien (código ${A_RC})." '[[ ${A_RC} -eq 0 ]]'
check "Al terminar A, el bloqueo ya no existe." '! object_exists "${BUCKET}" "${LOCK_KEY}"'
LAST="$(terraform -chdir="${WORK}/B" output -raw last_writer 2>/dev/null | tr -d '\r' || true)"
check "El estado lo escribió A; B no lo modificó mientras estaba bloqueado (last_writer=${LAST})." '[[ "${LAST}" == "A" ]]'

log "B: terraform apply ahora que el bloqueo está libre..."
terraform -chdir="${WORK}/B" apply -auto-approve -input=false -lock-timeout=60s -no-color \
    -var run_label=B -var hold_seconds=20 > "${WORK}/b-apply.log" 2>&1 && B_RC=0 || B_RC=$?
LAST="$(terraform -chdir="${WORK}/A" output -raw last_writer 2>/dev/null | tr -d '\r' || true)"
check "El apply de B termina bien (código ${B_RC}) y A ve el estado de B (last_writer=${LAST})." '[[ ${B_RC} -eq 0 && "${LAST}" == "B" ]]'
VERSIONS="$(aws_cli s3api list-object-versions --bucket "${BUCKET}" --prefix "${KEY}" \
    --query "length(Versions[?Key=='${KEY}'])" --output text | tr -d '\r')"
log "Versiones del estado de prueba en el bucket: ${VERSIONS} (una por cada escritura)."

# 4. Limpieza -------------------------------------------------------------------
if [[ "${KEEP_STATE}" == "false" ]]; then
    terraform -chdir="${WORK}/B" destroy -auto-approve -input=false -lock-timeout=60s -no-color \
        -var run_label=B -var hold_seconds=20 > "${WORK}/b-destroy.log" 2>&1 || warn "Falló el destroy de la prueba; revisa el estado ${KEY}."
    # Versiones y marcadores de borrado del estado y de los .tflock: una fila por objeto.
    for kind in Versions DeleteMarkers; do
        aws_cli s3api list-object-versions --bucket "${BUCKET}" --prefix "tests/state-lock/" \
            --query "${kind}[].[Key,VersionId]" --output text \
            | tr -d '\r' | while read -r k v; do
                [[ -n "${k}" && "${k}" != "None" ]] || continue
                aws_cli s3api delete-object --bucket "${BUCKET}" --key "${k}" --version-id "${v}" >/dev/null
            done
    done
    REMAINING="$(aws_cli s3api list-object-versions --bucket "${BUCKET}" --prefix "tests/state-lock/" \
        --query 'length([Versions[], DeleteMarkers[]][])' --output text | tr -d '\r')"
    check "Se borraron el estado de prueba y todas sus versiones (quedan ${REMAINING})." '[[ "${REMAINING}" == "0" ]]'
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    fail "La prueba de bloqueo tuvo ${FAILURES} fallas. Reporte: ${REPORT#"${REPO_ROOT}/"}"
fi
ok "CA2 verificado: dos ejecuciones concurrentes no aplican el mismo estado a la vez. Reporte: ${REPORT#"${REPO_ROOT}/"}"
