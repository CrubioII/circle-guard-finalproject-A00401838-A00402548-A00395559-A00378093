#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Funciones comunes de los scripts de Kubernetes (US-21)
#
# Se carga con: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Define K8S_DIR, ROOT_DIR, mensajes, validación de ambiente y la descarga de
# herramientas con versión fija y verificación SHA-256 (kubectl, kubeconform, yq).
# =============================================================================

# En Git Bash (Windows) se usan rutas C:/... para que también las entiendan
# binarios nativos como yq.exe o kubeconform.exe.
K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"
ROOT_DIR="$(cd "${K8S_DIR}/../.." && { pwd -W 2>/dev/null || pwd; })"
ALL_ENVS=(dev stage prod)
MIDDLEWARE=(postgres neo4j zookeeper kafka redis openldap)
SECRET_NAME="circleguard-middleware"
# Microservicios (US-37): Deployment y Service con el mismo nombre que en compose.
SERVICES=(auth-service identity-service promotion-service form-service gateway-service
          notification-service dashboard-service file-service web-client)
APP_SECRET_NAME="circleguard-app"

log()  { printf '[k8s] %s\n' "$*"; }
ok()   { printf '[k8s][OK]    %s\n' "$*"; }
warn() { printf '[k8s][AVISO] %s\n' "$*" >&2; }
fail() { printf '[k8s][ERROR] %s\n' "$*" >&2; exit 1; }

require_env() {
    case "$1" in
        dev|stage|prod) ;;
        *) fail "Ambiente inválido '$1'. Usa dev, stage o prod." ;;
    esac
}

namespace_for() { printf 'circleguard-%s' "$1"; }

# --- Herramientas con versión fija ------------------------------------------
KUBECTL_VERSION="v1.32.2"
KUBECONFORM_VERSION="v0.6.7"
YQ_VERSION="v4.44.3"
TOOLS_DIR="${CG_TOOLS_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/circleguard/tools}"

platform() {
    local os arch
    case "$(uname -s)" in
        Linux) os=linux ;;
        MINGW*|MSYS*|CYGWIN*) os=windows ;;
        *) fail "Sistema operativo no soportado para descargar herramientas: $(uname -s)." ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) fail "Arquitectura no soportada: $(uname -m)." ;;
    esac
    printf '%s_%s' "${os}" "${arch}"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# download_verified <url> <destino> <sha256>
download_verified() {
    local url="$1" dest="$2" expected="$3" tmp
    tmp="$(mktemp "${TOOLS_DIR}/.download.XXXXXX")"
    curl -fsSL --retry 3 -m 120 -o "${tmp}" "${url}" || { rm -f "${tmp}"; fail "No se pudo descargar ${url}."; }
    if [[ "$(sha256_of "${tmp}")" != "${expected}" ]]; then
        rm -f "${tmp}"
        fail "El SHA-256 de ${url} no coincide; se descarta el archivo."
    fi
    mv "${tmp}" "${dest}"
}

# ensure_tool <kubectl|kubeconform|yq>: imprime la ruta del binario. Usa el del
# PATH si existe y, si no, descarga la versión fija en ${TOOLS_DIR}.
ensure_tool() {
    local name="$1" plat ext="" bin url sum
    if command -v "${name}" >/dev/null 2>&1; then command -v "${name}"; return; fi
    plat="$(platform)"
    [[ "${plat}" == windows_* ]] && ext=".exe"
    mkdir -p "${TOOLS_DIR}"
    local version
    case "${name}" in
        kubectl) version="${KUBECTL_VERSION}" ;;
        kubeconform) version="${KUBECONFORM_VERSION}" ;;
        yq) version="${YQ_VERSION}" ;;
        *) fail "Herramienta desconocida: ${name}." ;;
    esac
    bin="${TOOLS_DIR}/${name}-${version}${ext}"
    if [[ -x "${bin}" ]]; then printf '%s' "${bin}"; return; fi

    case "${name}:${plat}" in
        kubectl:linux_amd64) sum=4f6a959dcc5b702135f8354cc7109b542a2933c46b808b248a214c1f69f817ea ;;
        kubectl:linux_arm64) sum=7381bea99c83c264100f324c2ca6e7e13738a73b8928477ac805991440a065cd ;;
        kubeconform:linux_amd64) sum=95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73 ;;
        kubeconform:linux_arm64) sum=dc82f79bb03c5479b1ae5fd4af221e4b5a3111f62bf01a2795d9c5c20fa96644 ;;
        kubeconform:windows_amd64) sum=450a561ae833cbd1fc41201f7ebb64395c56e7d01e2dc954332143bff81277a3 ;;
        yq:linux_amd64) sum=a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7 ;;
        yq:linux_arm64) sum=0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156 ;;
        yq:windows_amd64) sum=d509d51e6db30ebb7c9363b7ca8714224f93a456a421d7a7819ab564b868acc7 ;;
        *) fail "No hay binario verificado de ${name} para ${plat}; instálalo y vuelve a intentar." ;;
    esac

    log "Descargando ${name} para ${plat} en ${TOOLS_DIR}..." >&2
    case "${name}" in
        kubectl)
            url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${plat%_*}/${plat#*_}/kubectl"
            download_verified "${url}" "${bin}" "${sum}" ;;
        yq)
            url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${plat}${ext}"
            download_verified "${url}" "${bin}" "${sum}" ;;
        kubeconform)
            local archive tmpdir
            tmpdir="$(mktemp -d "${TOOLS_DIR}/.kubeconform.XXXXXX")"
            if [[ "${plat}" == windows_* ]]; then
                archive="${tmpdir}/kubeconform.zip"
                download_verified "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${plat/_/-}.zip" "${archive}" "${sum}"
                unzip -q -o "${archive}" kubeconform.exe -d "${tmpdir}"
                mv "${tmpdir}/kubeconform.exe" "${bin}"
            else
                archive="${tmpdir}/kubeconform.tar.gz"
                download_verified "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${plat/_/-}.tar.gz" "${archive}" "${sum}"
                tar -xzf "${archive}" -C "${tmpdir}" kubeconform
                mv "${tmpdir}/kubeconform" "${bin}"
            fi
            rm -rf "${tmpdir}" ;;
    esac
    chmod +x "${bin}"
    printf '%s' "${bin}"
}
