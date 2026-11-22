#!/usr/bin/env bash
# =============================================================================
# Crea o actualiza el backend remoto de Terraform de CircleGuard (US-36)
#
# Uso:
#   bash infra/terraform/scripts/bootstrap-backend.sh --profile circleguard-terraform --plan-only
#   bash infra/terraform/scripts/bootstrap-backend.sh --profile circleguard-terraform
#
# Opciones:
#   --profile <p>    perfil del AWS CLI (si no, AWS_PROFILE o la cadena estándar)
#   --region <r>     región del bucket (por defecto: us-east-2)
#   --plan-only      solo muestra el plan, no cambia nada
#   --auto-approve   aplica sin pedir confirmación
#
# Primera vez (el bucket no existe):
#   1. Aplica infra/terraform/bootstrap con estado local temporal.
#   2. Migra ese estado al bucket recién creado (bootstrap/terraform.tfstate).
#   3. Comprueba el estado remoto y borra la copia local.
# Siguientes veces: plan o apply del mismo stack con el backend remoto.
# Al final genera backend.hcl en bootstrap y en los tres ambientes.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backend-lib.sh"

PLAN_ONLY=false
APPROVE=()
PROFILE_ARGS=()

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) [[ $# -ge 2 ]] || fail "--profile necesita un valor."; use_profile "$2"; PROFILE_ARGS=(--profile "$2"); shift ;;
        --region) [[ $# -ge 2 ]] || fail "--region necesita un valor."; AWS_REGION="$2"; shift ;;
        --plan-only) PLAN_ONLY=true ;;
        --auto-approve) APPROVE=(-auto-approve) ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done

require_tools
export TF_IN_AUTOMATION=1
export AWS_REGION
DIR="$(root_dir bootstrap)"
KEY="$(state_key bootstrap)"
ACCOUNT="$(account_id)"
BUCKET="$(state_bucket "${ACCOUNT}")"
OVERRIDE="${DIR}/backend_override.tf"
tf() { terraform -chdir="${DIR}" "$@"; }

# El override de estado local nunca debe quedar en la carpeta.
trap 'rm -f "${OVERRIDE}"' EXIT

write_backend_hcl bootstrap "${BUCKET}" >/dev/null
log "Cuenta ${ACCOUNT}, bucket ${BUCKET} (${AWS_REGION})."

if bucket_exists "${BUCKET}"; then
    log "El bucket ya existe: uso el estado remoto s3://${BUCKET}/${KEY}."
    object_exists "${BUCKET}" "${KEY}" || fail "El bucket existe pero no tiene ${KEY}. No sigo para no duplicar recursos; revisa el bucket o importa el estado."
    tf init -backend-config=backend.hcl -input=false -reconfigure -no-color >/dev/null
    if [[ "${PLAN_ONLY}" == "true" ]]; then
        tf plan -input=false -lock-timeout=60s -no-color
    else
        tf apply -input=false -lock-timeout=60s -no-color "${APPROVE[@]+"${APPROVE[@]}"}"
    fi
else
    log "El bucket no existe: primera creación con estado local temporal."
    [[ ! -f "${DIR}/terraform.tfstate" || "${PLAN_ONLY}" == "true" ]] \
        || fail "Ya hay un bootstrap/terraform.tfstate local de un intento anterior. Revísalo antes de seguir."
    printf '%s\n' '# Temporal (bootstrap-backend.sh): estado local hasta que exista el bucket.' \
        'terraform {' '  backend "local" {}' '}' > "${OVERRIDE}"
    tf init -input=false -reconfigure -no-color >/dev/null

    if [[ "${PLAN_ONLY}" == "true" ]]; then
        tf plan -input=false -no-color
        ok "Plan del backend listo. No se cambió nada."
        exit 0
    fi

    tf apply -input=false -no-color "${APPROVE[@]+"${APPROVE[@]}"}"
    bucket_exists "${BUCKET}" || fail "El apply terminó pero el bucket ${BUCKET} no responde."

    log "Migrando el estado local a s3://${BUCKET}/${KEY}..."
    rm -f "${OVERRIDE}"
    tf init -backend-config=backend.hcl -migrate-state -force-copy -input=false -no-color >/dev/null
    object_exists "${BUCKET}" "${KEY}" || fail "No se encontró ${KEY} en el bucket después de migrar. El estado local sigue en ${DIR}."

    remote_count="$(tf state list -no-color | wc -l)"
    [[ "${remote_count}" -gt 0 ]] || fail "El estado remoto está vacío. El estado local sigue en ${DIR}."
    log "Recursos en el estado remoto: ${remote_count}."
    rm -f "${DIR}/terraform.tfstate" "${DIR}/terraform.tfstate.backup"
    ok "Estado del bootstrap migrado al bucket; se borró la copia local."
fi

if [[ "${PLAN_ONLY}" == "false" ]]; then
    bash "${BACKEND_LIB_DIR}/init-backend.sh" "${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}" --region "${AWS_REGION}"
    ok "Backend remoto listo: s3://${BUCKET} con bloqueo nativo (use_lockfile)."
fi
