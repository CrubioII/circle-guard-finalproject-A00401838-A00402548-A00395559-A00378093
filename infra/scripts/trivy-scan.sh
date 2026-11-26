#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Escaneo bloqueante con Trivy (US-38)
#
# Uso:
#   trivy-scan.sh config [--target infra/terraform --target deploy/k8s]
#   trivy-scan.sh image  --version X.Y.Z [--registry host:5000] [--image auth ...]
#
# config  `trivy config` (misconfiguraciones de IaC) sobre infra/terraform y deploy/k8s.
#         Los directorios que todavía no existen se omiten con un aviso.
# image   `trivy image` sobre las 9 imágenes publicadas por publish-docker-images.sh
#         (<registry>/circleguard/<img>:<version>). Escanea primero la imagen local del
#         demonio Docker (recién construida) y, si no está, la del registro.
#
# Política (US-38 CA2): severidad HIGH,CRITICAL con --exit-code 1. Las excepciones viven
# en .trivyignore (raíz del repo), cada una con su justificación y fecha de revisión.
# Se escanean TODOS los objetivos y al final sale con 1 si alguno falló, para que el
# reporte quede completo.
#
# Excepción temporal (US-39): con TRIVY_IMAGE_REPORT_ONLY=true el modo image genera los
# mismos reportes pero sale con 0 aunque haya hallazgos. El modo config sigue bloqueando
# siempre. Ver "Excepción temporal" en docs/arquitectura/PIPELINE_PLATAFORMA_US22_US38_US39.md.
#
# Reportes (US-38 CA3) en reports/trivy/:
#   <objetivo>.txt    tabla legible           <objetivo>.json  salida completa
#   junit/<obj>.xml   JUnit para Jenkins      summary.json     resultado por objetivo
#
# Variables: TRIVY_BIN, TRIVY_SEVERITY (HIGH,CRITICAL), TRIVY_TEMPLATES_DIR,
#   TRIVY_IGNORE_UNFIXED (true), TRIVY_IMAGE_REPORT_ONLY (false), REGISTRY_USER / REGISTRY_PASSWORD (registro Nexus),
#   DRY_RUN=1 (muestra los comandos).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${REPORT_DIR:-${ROOT_DIR}/reports/trivy}"
TRIVY_BIN="${TRIVY_BIN:-trivy}"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
TEMPLATES_DIR="${TRIVY_TEMPLATES_DIR:-/usr/local/share/trivy/templates}"
IGNORE_FILE="${TRIVY_IGNORE_FILE:-${ROOT_DIR}/.trivyignore}"
IGNORE_UNFIXED="${TRIVY_IGNORE_UNFIXED:-true}"
IMAGE_REPORT_ONLY="${TRIVY_IMAGE_REPORT_ONLY:-false}"
REGISTRY_URL="${REGISTRY_URL:-18.117.90.15:5000}"
NAMESPACE="${REGISTRY_NAMESPACE:-circleguard}"
DRY_RUN="${DRY_RUN:-0}"
ALL_IMAGES=(auth identity promotion notification form file gateway dashboard mobile)

log()  { printf '[trivy-us38] %s\n' "$*"; }
fail() { printf '[trivy-us38][ERROR] %s\n' "$*" >&2; exit "${2:-2}"; }
usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

MODE="${1:-}"; shift || true
TARGETS=(); IMAGES=(); VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGETS+=("${2:?--target necesita un valor}"); shift 2 ;;
        --image) IMAGES+=("${2:?--image necesita un valor}"); shift 2 ;;
        --version) VERSION="${2:?--version necesita un valor}"; shift 2 ;;
        --registry) REGISTRY_URL="${2:?--registry necesita un valor}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
done

case "${MODE}" in config|image) ;; -h|--help|"") usage; exit 0 ;; *) fail "Modo desconocido: ${MODE}" ;; esac
[[ "${SEVERITY}" =~ ^[A-Z,]+$ ]] || fail "TRIVY_SEVERITY inválida: ${SEVERITY}"
if [[ "${DRY_RUN}" != "1" ]]; then
    command -v "${TRIVY_BIN}" >/dev/null 2>&1 || fail "trivy no está instalado (imagen de Jenkins, infra/bootstrap/jenkins/Dockerfile)."
fi
mkdir -p "${REPORT_DIR}/junit"

ignore_flags=()
[[ -f "${IGNORE_FILE}" ]] && ignore_flags=(--ignorefile "${IGNORE_FILE}")
# Trivy 0.69+ ya no acepta --no-progress en "config"; la variable aplica a todos los modos.
export TRIVY_NO_PROGRESS=true
common_flags=(--severity "${SEVERITY}" --exit-code 1 ${ignore_flags[@]+"${ignore_flags[@]}"})

declare -a SUMMARY=()
FAILED=0

# Ejecuta un escaneo y escribe tabla, JSON y JUnit. Devuelve el exit code de la tabla.
scan() {
    local kind="$1" label="$2" target="$3"; shift 3
    local extra=("$@")
    local base="${REPORT_DIR}/${label}"
    local rc=0
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run] %s %s %s %s\n' "${TRIVY_BIN}" "${kind}" "${common_flags[*]} ${extra[*]:-}" "${target}"
        SUMMARY+=("{\"target\":\"${label}\",\"kind\":\"${kind}\",\"result\":\"DRY_RUN\"}")
        return 0
    fi
    # JSON completo (sin cortar el build) y JUnit para el reporte de pruebas de Jenkins.
    "${TRIVY_BIN}" "${kind}" ${extra[@]+"${extra[@]}"} --severity "${SEVERITY}" --exit-code 0 \
        ${ignore_flags[@]+"${ignore_flags[@]}"} \
        --format json --output "${base}.json" "${target}" || true
    if [[ -f "${TEMPLATES_DIR}/junit.tpl" ]]; then
        "${TRIVY_BIN}" "${kind}" ${extra[@]+"${extra[@]}"} --severity "${SEVERITY}" --exit-code 0 \
            ${ignore_flags[@]+"${ignore_flags[@]}"} \
            --format template --template "@${TEMPLATES_DIR}/junit.tpl" \
            --output "${REPORT_DIR}/junit/${label}.xml" "${target}" || true
    fi
    # Tabla legible: este es el escaneo que decide (exit-code 1 con HIGH/CRITICAL).
    set +e
    "${TRIVY_BIN}" "${kind}" ${extra[@]+"${extra[@]}"} "${common_flags[@]}" --format table --output "${base}.txt" "${target}"
    rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then
        log "OK    ${label}: sin hallazgos ${SEVERITY}."
        SUMMARY+=("{\"target\":\"${label}\",\"kind\":\"${kind}\",\"result\":\"PASS\"}")
    else
        log "FALLA ${label}: hallazgos ${SEVERITY} (ver reports/trivy/${label}.txt)."
        SUMMARY+=("{\"target\":\"${label}\",\"kind\":\"${kind}\",\"result\":\"FAIL\",\"exitCode\":${rc}}")
        FAILED=1
    fi
}

scan_config() {
    [[ ${#TARGETS[@]} -gt 0 ]] || TARGETS=(infra/terraform deploy/k8s)
    local t label
    for t in "${TARGETS[@]}"; do
        if [[ ! -d "${ROOT_DIR}/${t}" ]]; then
            log "AVISO ${t} no existe en este commit; se omite."
            SUMMARY+=("{\"target\":\"${t}\",\"kind\":\"config\",\"result\":\"SKIPPED\"}")
            continue
        fi
        label="config-$(printf '%s' "${t}" | tr '/' '-')"
        scan config "${label}" "${ROOT_DIR}/${t}"
    done
}

scan_images() {
    [[ -n "${VERSION}" ]] || fail "image necesita --version X.Y.Z (la calculada en US-12)."
    [[ "${VERSION}" != *latest* ]] || fail "Nunca se escanea ni publica el tag 'latest'."
    [[ ${#IMAGES[@]} -gt 0 ]] || IMAGES=("${ALL_IMAGES[@]}")
    local extra=(--image-src docker,remote)
    [[ "${IGNORE_UNFIXED}" == "true" ]] && extra+=(--ignore-unfixed)
    # Nexus expone el registro por HTTP (US-11).
    extra+=(--insecure)
    if [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
        export TRIVY_USERNAME="${REGISTRY_USER}" TRIVY_PASSWORD="${REGISTRY_PASSWORD}"
    fi
    local img ref
    for img in "${IMAGES[@]}"; do
        ref="${REGISTRY_URL}/${NAMESPACE}/${img}:${VERSION}"
        scan image "image-${img}" "${ref}" ${extra[@]+"${extra[@]}"}
    done
}

case "${MODE}" in
    config) scan_config ;;
    image) scan_images ;;
esac

# Solo el modo image admite reportar sin bloquear; el IaC siempre bloquea.
ENFORCED=true
[[ "${MODE}" == "image" && "${IMAGE_REPORT_ONLY}" == "true" ]] && ENFORCED=false

{
    printf '{"mode":"%s","severity":"%s","enforced":%s,"failed":%s,"results":[' "${MODE}" "${SEVERITY}" "${ENFORCED}" "$([[ ${FAILED} -eq 1 ]] && echo true || echo false)"
    (IFS=,; printf '%s' "${SUMMARY[*]:-}")
    printf ']}\n'
} > "${REPORT_DIR}/summary-${MODE}.json"

if [[ ${FAILED} -eq 1 && "${ENFORCED}" == "false" ]]; then
    log "AVISO Resultado: hay hallazgos ${SEVERITY} en las imágenes, pero TRIVY_IMAGE_REPORT_ONLY=true."
    log "AVISO Excepción temporal de US-39: se reporta sin bloquear. Revisar reports/trivy/image-*.txt."
    exit 0
fi
if [[ ${FAILED} -eq 1 ]]; then
    log "Resultado: hay hallazgos ${SEVERITY} sin excepción en .trivyignore. El pipeline se detiene."
    exit 1
fi
log "Resultado: ${MODE} sin hallazgos ${SEVERITY}."
