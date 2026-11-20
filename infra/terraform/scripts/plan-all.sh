#!/usr/bin/env bash
# =============================================================================
# Verificación de los módulos y ambientes Terraform de CircleGuard (US-35)
#
# Uso:
#   bash infra/terraform/scripts/plan-all.sh            # sin credenciales (proveedor simulado)
#   bash infra/terraform/scripts/plan-all.sh --real     # plan real contra AWS
#   bash infra/terraform/scripts/plan-all.sh --env prod # solo un ambiente
#
# Pasos:
#   1. terraform fmt -check en todo infra/terraform.
#   2. Por módulo: init -backend=false, validate y terraform test.
#   3. Por ambiente: init -backend=false, validate y terraform test (plan simulado
#      con los valores de terraform.tfvars). Guarda el plan y un resumen de recursos.
#   4. Con --real: init con envs/<env>/backend.hcl y terraform plan contra AWS.
#      Las credenciales salen de la cadena estándar de AWS (AWS_PROFILE, variables
#      de entorno o rol), nunca de este script.
#   5. Busca credenciales en texto plano en el código y en cada plan.
#
# Reportes: reports/terraform/<env>-plan.txt y <env>-resources.txt
# Sale con código distinto de 0 si cualquier paso falla.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TF_ROOT}/../.." && pwd)"
REPORT_DIR="${REPORT_DIR:-${REPO_ROOT}/reports/terraform}"

MODULES=(registry storage observability)
ENVS=(dev stage prod)
REAL_PLAN=false

# Patrones de credenciales que nunca deben aparecer en el código ni en un plan.
SECRET_PATTERNS='(AKIA|ASIA)[0-9A-Z]{16}|aws_secret_access_key|-----BEGIN [A-Z ]*PRIVATE KEY-----|(access_key|secret_key|password|token)[[:space:]]*=[[:space:]]*"[^"]+"'

log()  { printf '[terraform-us35][INFO]  %s\n' "$*"; }
ok()   { printf '[terraform-us35][OK]    %s\n' "$*"; }
fail() { printf '[terraform-us35][ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --real) REAL_PLAN=true ;;
        --env)
            [[ $# -ge 2 ]] || fail "--env necesita un valor: dev, stage o prod."
            case "$2" in dev|stage|prod) ENVS=("$2") ;; *) fail "Ambiente desconocido: $2" ;; esac
            shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done

command -v terraform >/dev/null 2>&1 || fail "terraform no está instalado."
mkdir -p "${REPORT_DIR}"
export TF_IN_AUTOMATION=1

scan_secrets() {
    local label="$1"; shift
    local hits
    hits="$(grep -EnI "${SECRET_PATTERNS}" "$@" 2>/dev/null || true)"
    if [[ -n "${hits}" ]]; then
        # Solo se muestra la ubicación, no el valor encontrado.
        printf '%s\n' "${hits}" | cut -d: -f1,2 >&2
        fail "Posibles credenciales en texto plano en ${label}."
    fi
    ok "Sin credenciales en texto plano: ${label}."
}

summarize_resources() {
    local plan_file="$1" summary_file="$2"
    grep -E '^[[:space:]]+# .* will be created' "${plan_file}" \
        | sed -E 's/^[[:space:]]+# (module\.[a-z_]+)\.([a-z0-9_]+)\..*/\1 \2/' \
        | sort | uniq -c > "${summary_file}" || true
    local total
    total="$(awk '{s += $1} END {print s + 0}' "${summary_file}")"
    printf 'TOTAL %s\n' "${total}" >> "${summary_file}"
    echo "${total}"
}

# 1. Formato ---------------------------------------------------------------
log "Revisando formato (terraform fmt -check)..."
terraform -chdir="${TF_ROOT}" fmt -recursive -check -diff >/dev/null || fail "Hay archivos sin formato. Ejecuta: terraform -chdir=infra/terraform fmt -recursive"
ok "Formato correcto."

# 2. Código sin credenciales ---------------------------------------------------
mapfile -t TF_FILES < <(find "${TF_ROOT}" -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.hcl' -o -name '*.hcl.example' \) -not -path '*/.terraform/*' -not -name '.terraform.lock.hcl')
scan_secrets "código Terraform (${#TF_FILES[@]} archivos)" "${TF_FILES[@]}"

# 3. Módulos -------------------------------------------------------------------
for module in "${MODULES[@]}"; do
    dir="${TF_ROOT}/modules/${module}"
    log "Módulo ${module}: init, validate y test..."
    terraform -chdir="${dir}" init -backend=false -input=false -no-color >/dev/null
    terraform -chdir="${dir}" validate -no-color >/dev/null
    terraform -chdir="${dir}" test -no-color > "${REPORT_DIR}/module-${module}-test.txt" 2>&1 \
        || { cat "${REPORT_DIR}/module-${module}-test.txt" >&2; fail "Fallaron las pruebas del módulo ${module}."; }
    ok "Módulo ${module}: $(grep -E 'passed, [0-9]+ failed' "${REPORT_DIR}/module-${module}-test.txt" | tail -1)"
done

# 4. Ambientes -----------------------------------------------------------------
for env in "${ENVS[@]}"; do
    dir="${TF_ROOT}/envs/${env}"
    plan_txt="${REPORT_DIR}/${env}-plan.txt"
    summary="${REPORT_DIR}/${env}-resources.txt"

    if [[ "${REAL_PLAN}" == "true" ]]; then
        [[ -f "${dir}/backend.hcl" ]] || fail "Falta envs/${env}/backend.hcl. Cópialo desde backend.hcl.example."
        log "Ambiente ${env}: plan real contra AWS..."
        terraform -chdir="${dir}" init -backend-config=backend.hcl -input=false -reconfigure -no-color >/dev/null
        terraform -chdir="${dir}" validate -no-color >/dev/null
        terraform -chdir="${dir}" plan -input=false -lock-timeout=60s -no-color -out=tfplan > "${plan_txt}"
        terraform -chdir="${dir}" show -json tfplan > "${REPORT_DIR}/${env}-plan.json"
        scan_secrets "plan JSON de ${env}" "${REPORT_DIR}/${env}-plan.json"
    else
        log "Ambiente ${env}: plan simulado (sin credenciales)..."
        terraform -chdir="${dir}" init -backend=false -input=false -no-color >/dev/null
        terraform -chdir="${dir}" validate -no-color >/dev/null
        terraform -chdir="${dir}" test -verbose -no-color > "${plan_txt}" 2>&1 \
            || { tail -40 "${plan_txt}" >&2; fail "Falló el plan simulado de ${env}."; }
    fi

    scan_secrets "plan de ${env}" "${plan_txt}"
    total="$(summarize_resources "${plan_txt}" "${summary}")"
    [[ "${total}" -gt 0 ]] || fail "El plan de ${env} no crea recursos. Revisa ${plan_txt}."
    ok "Ambiente ${env}: ${total} recursos planeados. Resumen en ${summary#"${REPO_ROOT}/"}"
done

ok "Verificación de Terraform completada para: ${ENVS[*]}."
