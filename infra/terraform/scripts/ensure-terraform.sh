#!/usr/bin/env bash
# =============================================================================
# Imprime la ruta de un binario de Terraform utilizable (US-36, etapa de Jenkins)
#
# Uso:
#   TERRAFORM_BIN="$(bash infra/terraform/scripts/ensure-terraform.sh)"
#
# Si hay un terraform en el PATH con versión 1.11 o superior, usa ese. Si no,
# descarga la versión fija ${TERRAFORM_VERSION} de releases.hashicorp.com, verifica
# su SHA-256 contra el valor de este archivo y la deja en
# ${CG_TOOLS_DIR:-~/.cache/circleguard/tools}. Las siguientes ejecuciones la reutilizan.
# Solo escribe la ruta en stdout; los mensajes van a stderr.
# =============================================================================
set -euo pipefail

TERRAFORM_VERSION="1.14.6"
MIN_VERSION="1.11.0"
TOOLS_DIR="${CG_TOOLS_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/circleguard/tools}"

log()  { printf '[terraform][INFO]  %s\n' "$*" >&2; }
fail() { printf '[terraform][ERROR] %s\n' "$*" >&2; exit 1; }

version_ok() {
    local v
    v="$("$1" version 2>/dev/null | head -1 | sed -nE 's/^Terraform v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
    [[ -n "${v}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "${MIN_VERSION}" "${v}" | sort -V | head -1)" == "${MIN_VERSION}" ]]
}

if command -v terraform >/dev/null 2>&1 && version_ok "$(command -v terraform)"; then
    command -v terraform
    exit 0
fi

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) fail "Sistema operativo no soportado: $(uname -s)." ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) fail "Arquitectura no soportada: $(uname -m)." ;;
esac
plat="${os}_${arch}"
ext=""
[[ "${os}" == windows ]] && ext=".exe"

# SHA-256 de terraform_${TERRAFORM_VERSION}_<plataforma>.zip, copiados del archivo
# SHA256SUMS oficial de la versión.
case "${plat}" in
    linux_amd64)   sum=364c6ee08b0cb8fcbb28a115aacb2aa48e88abc56c149170bd65c2f75d98ea8d ;;
    linux_arm64)   sum=190037f64695556ac75965c00da5d85b3663f38553d909e9a51c4490cba4b6c1 ;;
    darwin_arm64)  sum=5d91a8d6877e792de00be8db2324a2561edeb312ec2ff141b877131b82622c76 ;;
    windows_amd64) sum=94e9be396dffde19df74744000fe3f5522546048bc81b5604a02328ac7eb1ab5 ;;
    *) fail "No hay binario verificado de Terraform para ${plat}; instálalo y vuelve a intentar." ;;
esac

# Carpeta propia por versión, para que el binario se llame "terraform" y pueda ir al PATH.
bin="${TOOLS_DIR}/terraform-${TERRAFORM_VERSION}/terraform${ext}"
if [[ -x "${bin}" ]] && version_ok "${bin}"; then
    printf '%s\n' "${bin}"
    exit 0
fi

command -v curl >/dev/null 2>&1 || fail "Falta curl para descargar Terraform."
mkdir -p "${TOOLS_DIR}" "$(dirname "${bin}")"
tmpdir="$(mktemp -d "${TOOLS_DIR}/.terraform.XXXXXX")"
trap 'rm -rf "${tmpdir}"' EXIT
archive="${tmpdir}/terraform.zip"
url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${plat}.zip"

log "Descargando Terraform ${TERRAFORM_VERSION} para ${plat} en ${TOOLS_DIR}..."
curl -fsSL --retry 3 -m 300 -o "${archive}" "${url}" || fail "No se pudo descargar ${url}."

if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "${archive}" | awk '{print $1}')"
else actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"; fi
[[ "${actual}" == "${sum}" ]] || fail "El SHA-256 de ${url} no coincide; se descarta el archivo."

# El agente puede no tener unzip: se prueba con python3 y con jar (JDK) como respaldo.
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "${archive}" "terraform${ext}" -d "${tmpdir}"
elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract(sys.argv[2], sys.argv[3])' "${archive}" "terraform${ext}" "${tmpdir}"
elif command -v jar >/dev/null 2>&1; then
    (cd "${tmpdir}" && jar xf terraform.zip "terraform${ext}")
else
    fail "No hay unzip, python3 ni jar para descomprimir Terraform."
fi

chmod +x "${tmpdir}/terraform${ext}"
mv "${tmpdir}/terraform${ext}" "${bin}"
version_ok "${bin}" || fail "El binario descargado no responde a 'terraform version'."
log "Terraform ${TERRAFORM_VERSION} verificado: ${bin}"
printf '%s\n' "${bin}"
