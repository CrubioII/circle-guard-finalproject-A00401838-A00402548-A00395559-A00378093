#!/usr/bin/env bash
# =============================================================================
# Terraform en el pipeline de Jenkins (US-22)
#
# Uso:
#   tf-pipeline.sh plan  --env <dev|stage|prod> [--dry-run]
#   tf-pipeline.sh apply --env <dev|stage|prod> [--dry-run]
#
# plan:
#   init con el backend S3 de US-36 (bloqueo nativo), validate, plan -out y reportes:
#     reports/terraform/<env>.tfplan       plan binario (lo consume apply)
#     reports/terraform/<env>-plan.txt     plan legible (artefacto de Jenkins)
#     reports/terraform/<env>-plan.json    plan en JSON (terraform show -json)
#     reports/terraform/<env>-summary.json acciones por tipo (create/update/delete)
#   Sale con 0 aunque haya cambios (usa -detailed-exitcode solo para el resumen).
#
# apply:
#   Aplica EXACTAMENTE el plan guardado por `plan` en la misma ejecución. Si no existe,
#   falla: nunca se aplica un plan que nadie revisó.
#
# Backend (sin datos de la cuenta en Git):
#   TF_STATE_BUCKET  bucket del estado. Si falta, se arma como
#                    circleguard-terraform-state-<ID_CUENTA> con aws sts get-caller-identity.
#   El bloqueo es <clave>.tflock en el mismo bucket (use_lockfile, US-36); no hay tabla.
#   TF_STATE_REGION  región del backend (por defecto us-east-2, la Región del proyecto)
#   TF_STATE_KEY     clave del estado (por defecto envs/<env>/platform.tfstate)
#
# Credenciales: la cadena estándar de AWS (en Jenkins, la credencial 'aws-terraform'
# inyectada como AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY). Este script nunca las imprime.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TF_ROOT}/../.." && pwd)"
REPORT_DIR="${REPORT_DIR:-${REPO_ROOT}/reports/terraform}"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"

COMMAND="${1:-}"; shift || true
ENV_NAME=""
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '[terraform-us22][%s] %s\n' "${ENV_NAME:-?}" "$*"; }
fail() { printf '[terraform-us22][%s][ERROR] %s\n' "${ENV_NAME:-?}" "$*" >&2; exit "${2:-1}"; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="${2:?--env necesita un valor}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
done

case "${COMMAND}" in plan|apply) ;; -h|--help|"") usage; exit 0 ;; *) fail "Comando desconocido: ${COMMAND}" ;; esac
case "${ENV_NAME}" in dev|stage|prod) ;; *) fail "--env debe ser dev, stage o prod." ;; esac

ENV_DIR="${TF_ROOT}/envs/${ENV_NAME}"
[[ -d "${ENV_DIR}" ]] || fail "No existe ${ENV_DIR}."
PLAN_FILE="${REPORT_DIR}/${ENV_NAME}.tfplan"
mkdir -p "${REPORT_DIR}"
export TF_IN_AUTOMATION=1 TF_INPUT=0

run() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

tf() { run "${TERRAFORM_BIN}" -chdir="${ENV_DIR}" "$@"; }

resolve_state_bucket() {
    if [[ -n "${TF_STATE_BUCKET:-}" ]]; then
        printf '%s' "${TF_STATE_BUCKET}"
        return
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf 'circleguard-terraform-state-<ID_CUENTA>'
        return
    fi
    command -v aws >/dev/null 2>&1 || fail "Falta TF_STATE_BUCKET y no hay AWS CLI para deducirlo."
    local account
    account="$(aws sts get-caller-identity --query Account --output text)" \
        || fail "No se pudo leer la cuenta AWS (¿credencial 'aws-terraform' inyectada?)."
    printf 'circleguard-terraform-state-%s' "${account}"
}

terraform_init() {
    local bucket key region
    bucket="$(resolve_state_bucket)"
    key="${TF_STATE_KEY:-envs/${ENV_NAME}/platform.tfstate}"
    region="${TF_STATE_REGION:-us-east-2}"
    log "init: backend s3://${bucket}/${key} (${region}), bloqueo nativo de S3"
    tf init -reconfigure -no-color \
        -backend-config="bucket=${bucket}" \
        -backend-config="key=${key}" \
        -backend-config="region=${region}" \
        -backend-config="use_lockfile=true" \
        -backend-config="encrypt=true"
}

write_summary() {
    local json="$1" summary="$2" exit_code="$3"
    if [[ "${DRY_RUN}" == "1" ]] || ! command -v jq >/dev/null 2>&1 || [[ ! -s "${json}" ]]; then
        printf '{"env":"%s","planExitCode":%s}\n' "${ENV_NAME}" "${exit_code}" > "${summary}"
        return
    fi
    jq --arg env "${ENV_NAME}" --argjson code "${exit_code}" '{
        env: $env,
        planExitCode: $code,
        hasChanges: ($code == 2),
        create: [.resource_changes[]? | select(.change.actions | index("create")) | .address],
        update: [.resource_changes[]? | select(.change.actions == ["update"]) | .address],
        delete: [.resource_changes[]? | select(.change.actions | index("delete")) | .address]
    }' "${json}" > "${summary}"
}

cmd_plan() {
    terraform_init
    tf validate -no-color
    local rc=0
    if [[ "${DRY_RUN}" == "1" ]]; then
        tf plan -no-color -lock-timeout=5m -detailed-exitcode -out="${PLAN_FILE}"
    else
        set +e
        "${TERRAFORM_BIN}" -chdir="${ENV_DIR}" plan -no-color -lock-timeout=5m -detailed-exitcode \
            -out="${PLAN_FILE}" | tee "${REPORT_DIR}/${ENV_NAME}-plan.log"
        rc=${PIPESTATUS[0]}
        set -e
        # -detailed-exitcode: 0 sin cambios, 1 error, 2 con cambios.
        [[ ${rc} -eq 0 || ${rc} -eq 2 ]] || fail "terraform plan falló (exit ${rc})." "${rc}"
        "${TERRAFORM_BIN}" -chdir="${ENV_DIR}" show -no-color "${PLAN_FILE}" > "${REPORT_DIR}/${ENV_NAME}-plan.txt"
        "${TERRAFORM_BIN}" -chdir="${ENV_DIR}" show -json "${PLAN_FILE}" > "${REPORT_DIR}/${ENV_NAME}-plan.json"
    fi
    write_summary "${REPORT_DIR}/${ENV_NAME}-plan.json" "${REPORT_DIR}/${ENV_NAME}-summary.json" "${rc}"
    if [[ ${rc} -eq 2 ]]; then
        log "plan con cambios: revisa reports/terraform/${ENV_NAME}-plan.txt"
    else
        log "plan sin cambios (o dry-run)."
    fi
}

cmd_apply() {
    if [[ "${DRY_RUN}" != "1" && ! -s "${PLAN_FILE}" ]]; then
        fail "No existe ${PLAN_FILE}: apply solo aplica un plan generado en esta misma ejecución." 3
    fi
    terraform_init
    log "apply del plan guardado ${PLAN_FILE##*/}"
    tf apply -no-color -lock-timeout=5m -auto-approve "${PLAN_FILE}"
    log "apply completado."
}

command -v "${TERRAFORM_BIN}" >/dev/null 2>&1 || [[ "${DRY_RUN}" == "1" ]] || fail "terraform no está instalado."
case "${COMMAND}" in
    plan) cmd_plan ;;
    apply) cmd_apply ;;
esac
