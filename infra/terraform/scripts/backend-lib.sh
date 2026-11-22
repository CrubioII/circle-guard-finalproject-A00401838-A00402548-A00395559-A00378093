#!/usr/bin/env bash
# Funciones comunes de los scripts del backend remoto de Terraform (US-36).
# Se carga con: source "$(dirname "${BASH_SOURCE[0]}")/backend-lib.sh"
# Las credenciales salen de la cadena estándar de AWS (AWS_PROFILE, variables de
# entorno o rol). Ningún script las recibe, las imprime ni las guarda.

BACKEND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$(cd "${BACKEND_LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TF_ROOT}/../.." && pwd)"
REPORT_DIR="${REPORT_DIR:-${REPO_ROOT}/reports/terraform}"

PROJECT="${PROJECT:-circleguard}"
AWS_REGION="${AWS_REGION:-us-east-2}"
AWS_CLI="${AWS_CLI:-aws}"
ALL_ROOTS=(bootstrap dev stage prod)

log()  { printf '[backend][INFO]  %s\n' "$*"; }
ok()   { printf '[backend][OK]    %s\n' "$*"; }
warn() { printf '[backend][WARN]  %s\n' "$*" >&2; }
fail() { printf '[backend][ERROR] %s\n' "$*" >&2; exit 1; }

require_tools() {
    command -v terraform >/dev/null 2>&1 || fail "terraform no está instalado."
    command -v "${AWS_CLI}" >/dev/null 2>&1 || fail "No se encontró el AWS CLI (${AWS_CLI}). Instálalo o define AWS_CLI con su ruta."
}

aws_cli() { "${AWS_CLI}" --region "${AWS_REGION}" "$@"; }

# Selecciona el perfil para el AWS CLI y para Terraform (backend y proveedor).
use_profile() {
    [[ -z "${1:-}" ]] || export AWS_PROFILE="$1"
}

account_id() {
    local id
    id="$(aws_cli sts get-caller-identity --query Account --output text 2>/dev/null | tr -d '\r')" \
        || fail "No hay credenciales de AWS válidas. Usa --profile o define AWS_PROFILE."
    [[ "${id}" =~ ^[0-9]{12}$ ]] || fail "ID de cuenta inesperado: ${id}"
    printf '%s' "${id}"
}

state_bucket() { printf '%s-terraform-state-%s' "${PROJECT}" "$1"; }

# Carpeta y clave de estado de cada raíz de Terraform.
root_dir() {
    case "$1" in
        bootstrap) printf '%s/bootstrap' "${TF_ROOT}" ;;
        dev|stage|prod) printf '%s/envs/%s' "${TF_ROOT}" "$1" ;;
        *) fail "Raíz desconocida: $1 (bootstrap, dev, stage o prod)." ;;
    esac
}

state_key() {
    case "$1" in
        bootstrap) printf 'bootstrap/terraform.tfstate' ;;
        *) printf 'envs/%s/platform.tfstate' "$1" ;;
    esac
}

bucket_exists() {
    aws_cli s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

object_exists() {
    aws_cli s3api head-object --bucket "$1" --key "$2" >/dev/null 2>&1
}

# Escribe backend.hcl (ignorado por Git) para una raíz. Solo contiene el nombre
# del bucket, la clave y la región; no lleva credenciales.
write_backend_hcl() {
    local root="$1" bucket="$2" file key
    file="$(root_dir "${root}")/backend.hcl"
    key="${3:-$(state_key "${root}")}"
    cat > "${file}" <<EOF
# Generado por init-backend.sh. Ignorado por Git.
bucket       = "${bucket}"
key          = "${key}"
region       = "${AWS_REGION}"
use_lockfile = true
encrypt      = true
EOF
    printf '%s' "${file}"
}
