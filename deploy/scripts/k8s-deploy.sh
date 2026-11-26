#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Despliegue, verificación y rollback en Kubernetes (US-39 / US-28)
#
# Uso:
#   k8s-deploy.sh deploy   --env <dev|stage|prod> --version X.Y.Z [--dry-run]
#   k8s-deploy.sh verify   --env <env> --version X.Y.Z [--report reports/ci/k8s-<env>.json] [--dry-run]
#   k8s-deploy.sh rollback --env <env> [--to X.Y.Z] [--dry-run]
#   k8s-deploy.sh status   --env <env>
#
# deploy   (US-39 CA1) Arma una kustomization temporal en build/k8s-release/<env>/ que usa
#          deploy/k8s/overlays/<env> como base y fija las 9 imágenes de CircleGuard en
#          <REGISTRY_URL>/circleguard/<img>:X.Y.Z. Después `kubectl apply -k` y anota cada
#          Deployment con kubernetes.io/change-cause (versión, build) para el historial.
#          Registra la versión en el ConfigMap circleguard-release del namespace.
# verify   (US-39 CA2) `kubectl rollout status` de todos los Deployments y StatefulSets del
#          namespace y comprobación de que las imágenes de CircleGuard tienen la etiqueta
#          X.Y.Z. Si algo no queda listo, sale con 3 y la etapa de Jenkins falla.
# rollback (US-28 CA1) Sin --to: `kubectl rollout undo` de los Deployments de CircleGuard
#          (vuelven a la revisión anterior). Con --to: redeploy de esa etiqueta. En ambos
#          casos espera el rollout.
# status   Versión registrada, imágenes y revisiones de cada Deployment.
#
# Variables:
#   KUBECONFIG        kubeconfig del clúster k3s del ambiente (en Jenkins, credencial de
#                     tipo archivo 'kubeconfig-<env>'; ver deploy/k8s/scripts/get-kubeconfig.sh)
#   REGISTRY_URL      registro de imágenes (por defecto 18.117.90.15:5000)
#   K8S_NAMESPACE     namespace (por defecto circleguard-<env>, el de US-21)
#   K8S_OVERLAY_DIR   overlay (por defecto deploy/k8s/overlays/<env>)
#   ROLLOUT_TIMEOUT   tiempo máximo por recurso (por defecto 300s)
#   APP_SELECTOR      selector de los Deployments de la app (app.kubernetes.io/part-of=circleguard)
#   BUILD_URL / BUILD_NUMBER  se guardan en el change-cause y en el ConfigMap.
#
# Códigos de salida: 0 éxito | 1 uso | 2 faltan manifiestos o herramientas | 3 rollout fallido.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
REGISTRY_URL="${REGISTRY_URL:-18.117.90.15:5000}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-circleguard}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
APP_SELECTOR="${APP_SELECTOR:-app.kubernetes.io/part-of=circleguard}"
DRY_RUN="${DRY_RUN:-0}"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
# Nombres con los que publish-docker-images.sh sube cada imagen (US-11): el corto y el alias
# que usan los compose (<svc>-service, web-client). La kustomization fija ambos.
IMAGES=(auth identity promotion notification form file gateway dashboard mobile
        auth-service identity-service promotion-service notification-service form-service
        file-service gateway-service dashboard-service web-client)

log()  { printf '[k8s-deploy][%s] %s\n' "${ENV_NAME:-?}" "$*"; }
fail() { printf '[k8s-deploy][%s][ERROR] %s\n' "${ENV_NAME:-?}" "$*" >&2; exit "${2:-1}"; }
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

COMMAND="${1:-}"; shift || true
ENV_NAME=""; VERSION=""; TO=""; REPORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_NAME="${2:?--env necesita un valor}"; shift 2 ;;
        --version) VERSION="${2:?--version necesita un valor}"; shift 2 ;;
        --to) TO="${2:?--to necesita un valor}"; shift 2 ;;
        --report) REPORT="${2:?--report necesita un valor}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
done

case "${COMMAND}" in deploy|verify|rollback|status) ;; -h|--help|"") usage; exit 0 ;; *) fail "Comando desconocido: ${COMMAND}" ;; esac
case "${ENV_NAME}" in dev|stage|prod) ;; *) fail "--env debe ser dev, stage o prod." ;; esac

NAMESPACE="${K8S_NAMESPACE:-circleguard-${ENV_NAME}}"
OVERLAY_DIR="${K8S_OVERLAY_DIR:-${ROOT_DIR}/deploy/k8s/overlays/${ENV_NAME}}"
RELEASE_DIR="${ROOT_DIR}/build/k8s-release/${ENV_NAME}"

validate_version() {
    [[ "$1" != *latest* ]] || fail "Nunca se despliega el tag mutable 'latest'."
    [[ "$1" =~ ${SEMVER_RE} ]] || fail "Versión '$1' no cumple SemVer (X.Y.Z o X.Y.Z-rc.N)."
}

run() {
    if [[ "${DRY_RUN}" == "1" ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

k() { run "${KUBECTL}" -n "${NAMESPACE}" "$@"; }

require_tools() {
    [[ "${DRY_RUN}" == "1" ]] && return 0
    # Sin kubectl en el PATH (imagen de Jenkins sin reconstruir) se usa la versión fija y
    # verificada de deploy/k8s/scripts/lib.sh, la misma que descarga validate.sh.
    if ! command -v "${KUBECTL}" >/dev/null 2>&1; then
        KUBECTL="$(bash -c 'source "$1" && ensure_tool kubectl' _ "${ROOT_DIR}/deploy/k8s/scripts/lib.sh")" \
            || fail "kubectl no está instalado y no se pudo descargar." 2
    fi
    [[ -n "${KUBECONFIG:-}" || -f "${HOME}/.kube/config" ]] || fail "No hay KUBECONFIG para el clúster de ${ENV_NAME}." 2
}

# Kustomization de release: base = overlay del ambiente (US-21), imágenes = versión SemVer.
render_release() {
    local version="$1" rel img
    [[ -d "${OVERLAY_DIR}" ]] || fail "No existe ${OVERLAY_DIR} (manifiestos de US-21)." 2
    mkdir -p "${RELEASE_DIR}"
    rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "${OVERLAY_DIR}" "${RELEASE_DIR}")"
    {
        printf '# Generado por deploy/scripts/k8s-deploy.sh (US-39). No editar ni versionar.\n'
        printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n'
        printf 'resources:\n  - %s\n' "${rel}"
        printf 'commonAnnotations:\n  circleguard.io/release: "%s"\n' "${version}"
        printf 'images:\n'
        for img in "${IMAGES[@]}"; do
            # Coincide tanto con "circleguard/<img>" como con "<registro>/circleguard/<img>".
            printf '  - name: %s/%s\n    newName: %s/%s/%s\n    newTag: "%s"\n' \
                "${REGISTRY_NAMESPACE}" "${img}" "${REGISTRY_URL}" "${REGISTRY_NAMESPACE}" "${img}" "${version}"
            printf '  - name: %s/%s/%s\n    newTag: "%s"\n' \
                "${REGISTRY_URL}" "${REGISTRY_NAMESPACE}" "${img}" "${version}"
        done
    } > "${RELEASE_DIR}/kustomization.yaml"
    log "Kustomization de release en ${RELEASE_DIR#"${ROOT_DIR}/"}/kustomization.yaml"
}

record_release() {
    local version="$1" now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run] registrar circleguard-release version=%s en %s\n' "${version}" "${NAMESPACE}"
        return
    fi
    "${KUBECTL}" -n "${NAMESPACE}" create configmap circleguard-release \
        --from-literal=version="${version}" \
        --from-literal=deployedAt="${now}" \
        --from-literal=build="${BUILD_URL:-manual}" \
        --dry-run=client -o yaml | "${KUBECTL}" apply -f - >/dev/null
}

annotate_change_cause() {
    local cause="$1"
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run] %s -n %s annotate deployment -l %s kubernetes.io/change-cause=%q --overwrite\n' \
            "${KUBECTL}" "${NAMESPACE}" "${APP_SELECTOR}" "${cause}"
        return
    fi
    "${KUBECTL}" -n "${NAMESPACE}" annotate deployment -l "${APP_SELECTOR}" \
        "kubernetes.io/change-cause=${cause}" --overwrite >/dev/null 2>&1 || true
}

cmd_deploy() {
    local version="$1"
    validate_version "${version}"
    require_tools
    render_release "${version}"
    log "kubectl apply -k (namespace ${NAMESPACE}, versión ${version})"
    run "${KUBECTL}" apply -k "${RELEASE_DIR}"
    annotate_change_cause "CircleGuard ${version} build ${BUILD_NUMBER:-manual}"
    record_release "${version}"
    log "Manifiestos aplicados. La verificación la hace 'verify' (rollout status)."
}

# Imprime "kind/nombre" de Deployments y StatefulSets del namespace.
list_workloads() {
    "${KUBECTL}" -n "${NAMESPACE}" get deployments,statefulsets -o name 2>/dev/null || true
}

cmd_verify() {
    local version="$1" failed=() ok=() wl bad
    validate_version "${version}"
    require_tools
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run] %s -n %s rollout status <deployments y statefulsets> --timeout=%s\n' "${KUBECTL}" "${NAMESPACE}" "${ROLLOUT_TIMEOUT}"
        printf '[dry-run] comprobar que las imágenes */%s/* usan la etiqueta %s\n' "${REGISTRY_NAMESPACE}" "${version}"
        return 0
    fi
    local workloads
    workloads="$(list_workloads)"
    [[ -n "${workloads}" ]] || fail "No hay Deployments ni StatefulSets en ${NAMESPACE}." 3
    while read -r wl; do
        [[ -n "${wl}" ]] || continue
        if "${KUBECTL}" -n "${NAMESPACE}" rollout status "${wl}" --timeout="${ROLLOUT_TIMEOUT}"; then
            ok+=("${wl}")
        else
            failed+=("${wl}")
        fi
    done <<< "${workloads}"
    # Toda imagen de CircleGuard debe correr la versión pedida (nunca otra ni 'latest').
    bad="$("${KUBECTL}" -n "${NAMESPACE}" get deployments,statefulsets \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' \
        | awk -v ns="/${REGISTRY_NAMESPACE}/" -v tag=":${version}" '{for(i=2;i<=NF;i++) if (index($i, ns) && substr($i, length($i)-length(tag)+1) != tag) print $1 "=" $i}')"
    if [[ -n "${REPORT}" ]]; then
        mkdir -p "$(dirname "${REPORT}")"
        python3 - "${REPORT}" "${ENV_NAME}" "${NAMESPACE}" "${version}" "${ok[*]:-}" "${failed[*]:-}" "${bad}" <<'PY'
import json, sys
path, env, ns, version, ok, failed, bad = sys.argv[1:8]
json.dump({
    "env": env, "namespace": ns, "version": version, "platform": "k8s",
    "ready": ok.split(), "notReady": failed.split(),
    "wrongImages": [b for b in bad.splitlines() if b],
    "healthy": not failed.split() and not bad.strip(),
}, open(path, "w"), indent=2)
PY
    fi
    [[ -z "${bad}" ]] || fail "Imágenes con otra versión distinta de ${version}: ${bad//$'\n'/, }" 3
    if [[ ${#failed[@]} -gt 0 ]]; then
        # P3: un ambiente nuevo sin Secrets deja los pods en CreateContainerConfigError.
        # Jenkins no puede crearlos (US-26); se dice qué falta y cómo resolverlo.
        local no_config
        no_config="$("${KUBECTL}" -n "${NAMESPACE}" get pods \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
            | awk '/CreateContainerConfigError/ {print $1}' | paste -sd ' ' -)"
        if [[ -n "${no_config}" ]]; then
            printf '[k8s-deploy] Pods sin configuración (falta un Secret o una clave): %s\n' "${no_config}" >&2
            printf '[k8s-deploy] Un administrador debe correr: deploy/k8s/scripts/create-secrets.sh --env %s --generate --if-missing\n' "${ENV_NAME}" >&2
        fi
        fail "Rollout incompleto en ${NAMESPACE}: ${failed[*]}" 3
    fi
    log "Rollout completo: ${#ok[@]} recursos listos con la versión ${version}."
}

cmd_rollback() {
    require_tools
    if [[ -n "${TO}" ]]; then
        validate_version "${TO}"
        log "Rollback por redeploy de la etiqueta ${TO}"
        cmd_deploy "${TO}"
        cmd_verify "${TO}"
        return
    fi
    log "Rollback a la revisión anterior (kubectl rollout undo) de los Deployments ${APP_SELECTOR}"
    local deployments d
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run] %s -n %s rollout undo deployment/<cada deployment con %s>\n' "${KUBECTL}" "${NAMESPACE}" "${APP_SELECTOR}"
        printf '[dry-run] %s -n %s rollout status deployment/<...> --timeout=%s\n' "${KUBECTL}" "${NAMESPACE}" "${ROLLOUT_TIMEOUT}"
        return 0
    fi
    deployments="$("${KUBECTL}" -n "${NAMESPACE}" get deployments -l "${APP_SELECTOR}" -o name)"
    [[ -n "${deployments}" ]] || fail "No hay Deployments con ${APP_SELECTOR} en ${NAMESPACE}." 3
    while read -r d; do
        [[ -n "${d}" ]] || continue
        "${KUBECTL}" -n "${NAMESPACE}" rollout undo "${d}"
    done <<< "${deployments}"
    while read -r d; do
        [[ -n "${d}" ]] || continue
        "${KUBECTL}" -n "${NAMESPACE}" rollout status "${d}" --timeout="${ROLLOUT_TIMEOUT}" \
            || fail "El rollback de ${d} no quedó listo." 3
    done <<< "${deployments}"
    # La versión restaurada es la etiqueta que quedó en los contenedores de CircleGuard.
    local restored
    restored="$("${KUBECTL}" -n "${NAMESPACE}" get deployments -l "${APP_SELECTOR}" \
        -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' | sed 's/.*://')"
    [[ "${restored}" =~ ${SEMVER_RE} ]] && record_release "${restored}"
    log "Rollback completado: ${NAMESPACE} ejecuta ${restored:-la revisión anterior}."
}

cmd_status() {
    require_tools
    printf 'Namespace : %s\n' "${NAMESPACE}"
    printf 'Versión   : %s\n' "$("${KUBECTL}" -n "${NAMESPACE}" get configmap circleguard-release -o jsonpath='{.data.version}' 2>/dev/null || echo 'sin registro')"
    "${KUBECTL}" -n "${NAMESPACE}" get deployments,statefulsets -o wide || true
    local d
    for d in $("${KUBECTL}" -n "${NAMESPACE}" get deployments -l "${APP_SELECTOR}" -o name 2>/dev/null); do
        printf '\n%s\n' "${d}"
        "${KUBECTL}" -n "${NAMESPACE}" rollout history "${d}" | tail -n 5
    done
}

case "${COMMAND}" in
    deploy) [[ -n "${VERSION}" ]] || fail "deploy necesita --version"; cmd_deploy "${VERSION}" ;;
    verify) [[ -n "${VERSION}" ]] || fail "verify necesita --version"; cmd_verify "${VERSION}" ;;
    rollback) cmd_rollback ;;
    status) cmd_status ;;
esac
