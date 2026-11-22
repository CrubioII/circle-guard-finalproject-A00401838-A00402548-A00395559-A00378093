#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Kubeconfig del clúster k3s de un ambiente (US-21)
#
# El server k3s de US-20 publica su kubeconfig, ya apuntando a su IP elástica,
# en el parámetro SSM SecureString /circleguard/<env>/k3s/kubeconfig. Este
# script lo descarga con permisos 600 y renombra el contexto a circleguard-<env>.
#
# Uso:
#   export AWS_PROFILE=<perfil>          # credenciales en ~/.aws, nunca en el repo
#   bash deploy/k8s/scripts/get-kubeconfig.sh --env dev
#   export KUBECONFIG=~/.kube/circleguard-dev.yaml
# Opciones: --output <archivo>, --region <región> (por defecto us-east-2).
# Requisitos: AWS CLI v2 y permiso ssm:GetParameter + kms:Decrypt sobre el
# parámetro. La API (6443) solo acepta la VPC y compute_api_allowed_cidrs.
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME=""
OUTPUT=""
REGION="${AWS_REGION:-us-east-2}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="${2:?--env necesita un valor}"; shift ;;
        --output) OUTPUT="${2:?--output necesita un valor}"; shift ;;
        --region) REGION="${2:?--region necesita un valor}"; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done
[[ -n "${ENV_NAME}" ]] || fail "Falta --env (dev, stage o prod)."
require_env "${ENV_NAME}"
command -v aws >/dev/null 2>&1 || fail "Se necesita AWS CLI v2."
KUBECTL="$(ensure_tool kubectl)"

PARAMETER="/circleguard/${ENV_NAME}/k3s/kubeconfig"
OUTPUT="${OUTPUT:-${HOME}/.kube/circleguard-${ENV_NAME}.yaml}"
mkdir -p "$(dirname "${OUTPUT}")"

umask 077
TMP="$(mktemp "$(dirname "${OUTPUT}")/.kubeconfig.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT

log "Leyendo ${PARAMETER} (${REGION})..."
aws ssm get-parameter --region "${REGION}" --name "${PARAMETER}" --with-decryption \
    --query Parameter.Value --output text > "${TMP}" \
    || fail "No se pudo leer ${PARAMETER}. Revisa AWS_PROFILE y que el ambiente esté aplicado (US-20)."

if grep -q '^pendiente-de-arranque$' "${TMP}"; then
    fail "El server de ${ENV_NAME} todavía no publicó su kubeconfig. Espera a que termine el arranque de k3s."
fi
grep -q 'server: https://' "${TMP}" || fail "El parámetro no contiene un kubeconfig válido."

KUBECONFIG="${TMP}" "${KUBECTL}" config rename-context default "circleguard-${ENV_NAME}" >/dev/null 2>&1 || true
mv "${TMP}" "${OUTPUT}"
chmod 600 "${OUTPUT}"
trap - EXIT

ok "Kubeconfig de ${ENV_NAME} guardado en ${OUTPUT} (contexto circleguard-${ENV_NAME})."
printf 'export KUBECONFIG=%s\n' "${OUTPUT}"
