#!/usr/bin/env bash
# =============================================================================
# Conecta las raíces de Terraform al backend remoto de CircleGuard (US-36)
#
# Uso:
#   bash infra/terraform/scripts/init-backend.sh --profile circleguard-terraform
#   bash infra/terraform/scripts/init-backend.sh --env dev --init
#   bash infra/terraform/scripts/init-backend.sh --env bootstrap --no-check
#
# Opciones:
#   --env <raíz>    bootstrap, dev, stage, prod o all (por defecto: all)
#   --profile <p>   perfil del AWS CLI (si no, AWS_PROFILE o la cadena estándar)
#   --region <r>    región del bucket (por defecto: us-east-2)
#   --init          además ejecuta terraform init con el backend remoto
#   --no-check      no exige que el bucket ya exista (lo usa bootstrap-backend.sh)
#
# Genera <raíz>/backend.hcl con el bucket circleguard-terraform-state-<cuenta>,
# la clave de estado de la raíz y el bloqueo nativo de S3 (use_lockfile).
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backend-lib.sh"

ROOTS=("${ALL_ROOTS[@]}")
RUN_INIT=false
CHECK_BUCKET=true

usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            [[ $# -ge 2 ]] || fail "--env necesita un valor."
            case "$2" in
                all) ROOTS=("${ALL_ROOTS[@]}") ;;
                bootstrap|dev|stage|prod) ROOTS=("$2") ;;
                *) fail "Raíz desconocida: $2" ;;
            esac
            shift ;;
        --profile) [[ $# -ge 2 ]] || fail "--profile necesita un valor."; use_profile "$2"; shift ;;
        --region) [[ $# -ge 2 ]] || fail "--region necesita un valor."; AWS_REGION="$2"; shift ;;
        --init) RUN_INIT=true ;;
        --no-check) CHECK_BUCKET=false ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done

require_tools
ACCOUNT="$(account_id)"
BUCKET="$(state_bucket "${ACCOUNT}")"
log "Cuenta ${ACCOUNT}, bucket de estado ${BUCKET} (${AWS_REGION})."

if [[ "${CHECK_BUCKET}" == "true" ]]; then
    bucket_exists "${BUCKET}" || fail "El bucket ${BUCKET} no existe o no hay acceso. Créalo con: bash infra/terraform/scripts/bootstrap-backend.sh"
    ok "El bucket de estado existe y es accesible."
fi

for root in "${ROOTS[@]}"; do
    file="$(write_backend_hcl "${root}" "${BUCKET}")"
    ok "${root}: ${file#"${REPO_ROOT}/"} -> s3://${BUCKET}/$(state_key "${root}")"
    if [[ "${RUN_INIT}" == "true" ]]; then
        terraform -chdir="$(root_dir "${root}")" init -backend-config=backend.hcl -input=false -reconfigure -no-color >/dev/null
        ok "${root}: terraform init con el backend remoto."
    fi
done
