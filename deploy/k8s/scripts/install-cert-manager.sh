#!/usr/bin/env bash
# =============================================================================
# CircleGuard — cert-manager en el clúster de un ambiente (US-26)
#
# Lo corre un administrador una vez por clúster, antes del primer despliegue con TLS:
# el overlay trae Issuers y Certificates, y kubectl apply los rechaza si cert-manager
# no está instalado. Descarga el manifiesto oficial de la versión fija, comprueba su
# SHA-256, lo aplica y espera a que el webhook responda.
#
# Uso:
#   export KUBECONFIG=~/.kube/circleguard-dev.yaml      # administrador (get-kubeconfig.sh)
#   bash deploy/k8s/scripts/install-cert-manager.sh
# Opciones: --context <contexto>, --dry-run (solo descarga y verifica).
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CERT_MANAGER_VERSION="v1.21.3"
CERT_MANAGER_SHA256="c04a51295adda2b1a775146751f973e787190778c7f35180861d9678876e5c74"
CONTEXT=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --context) CONTEXT="${2:?--context necesita un valor}"; shift ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done
KUBECTL="$(ensure_tool kubectl)"
KCTL=("${KUBECTL}")
[[ -n "${CONTEXT}" ]] && KCTL+=(--context "${CONTEXT}")

mkdir -p "${TOOLS_DIR}"
MANIFEST="${TOOLS_DIR}/cert-manager-${CERT_MANAGER_VERSION}.yaml"
if [[ ! -f "${MANIFEST}" || "$(sha256_of "${MANIFEST}")" != "${CERT_MANAGER_SHA256}" ]]; then
    log "Descargando cert-manager ${CERT_MANAGER_VERSION}..."
    download_verified \
        "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
        "${MANIFEST}" "${CERT_MANAGER_SHA256}"
fi
ok "Manifiesto de cert-manager ${CERT_MANAGER_VERSION} verificado (SHA-256)."
[[ "${DRY_RUN}" == "true" ]] && exit 0

"${KCTL[@]}" apply -f "${MANIFEST}" >/dev/null
for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
    "${KCTL[@]}" -n cert-manager rollout status "deployment/${deployment}" --timeout=300s >/dev/null \
        || fail "cert-manager no quedó listo (${deployment})."
done
# El webhook tarda unos segundos más en aceptar recursos aunque el pod esté listo.
for _ in $(seq 1 30); do
    if "${KCTL[@]}" create --dry-run=server -f - >/dev/null 2>&1 <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: cg-webhook-check, namespace: cert-manager}
spec: {selfSigned: {}}
EOF
    then
        ok "cert-manager ${CERT_MANAGER_VERSION} instalado y su webhook responde."
        exit 0
    fi
    sleep 2
done
fail "El webhook de cert-manager no responde."
