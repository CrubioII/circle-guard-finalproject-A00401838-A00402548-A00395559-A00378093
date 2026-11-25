#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Validación de los manifiestos de Kubernetes (US-21)
#
# No necesita clúster ni credenciales. Para cada overlay (dev, stage, prod):
#   CA2  Genera el overlay con Kustomize y comprueba que todo queda en su
#        namespace circleguard-<env>, con Pod Security, ResourceQuota,
#        LimitRange y NetworkPolicy de aislamiento.
#   CA3  Comprueba que el middleware (postgres, neo4j, zookeeper, kafka, redis,
#        openldap) está completo, usa las mismas imágenes con versión fija que
#        deploy/compose, tiene probes y recursos, no expone puertos fuera del
#        clúster y toma las contraseñas solo del Secret circleguard-middleware.
#   US-37 Comprueba los 8 microservicios: Deployment y Service por cada uno, imagen
#        circleguard/<servicio> con versión, recursos, usuario no root, disco de solo
#        lectura, contraseñas solo desde Secrets y un único Ingress hacia sus APIs.
#   US-26 Comprueba el RBAC: cada microservicio con su propia cuenta de servicio sin
#        token, y jenkins-deployer sin comodines, sin Secrets y sin pods/exec.
#   +    Valida el esquema de cada recurso con kubeconform (-strict), revisa que
#        el volumen pedido quepa en la cuota y busca credenciales en texto plano.
#
# Uso:
#   bash deploy/k8s/scripts/validate.sh                  # los 3 ambientes
#   bash deploy/k8s/scripts/validate.sh --env prod       # uno solo
#   bash deploy/k8s/scripts/validate.sh --skip-schema    # sin kubeconform (sin red)
# Deja el render en reports/k8s/<env>.yaml y un resumen en <env>-summary.txt.
# Herramientas: kubectl, yq y kubeconform; si faltan, descarga versiones fijas
# verificadas con SHA-256 (ver scripts/lib.sh).
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENVS=()
SKIP_SCHEMA=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) [[ $# -ge 2 ]] || fail "--env necesita un valor."; require_env "$2"; ENVS+=("$2"); shift ;;
        --skip-schema) SKIP_SCHEMA=true ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) fail "Opción desconocida: $1" ;;
    esac
    shift
done
[[ ${#ENVS[@]} -gt 0 ]] || ENVS=("${ALL_ENVS[@]}")

KUBECTL="$(ensure_tool kubectl)"
YQ="$(ensure_tool yq)"
KUBECONFORM=""
[[ "${SKIP_SCHEMA}" == "true" ]] || KUBECONFORM="$(ensure_tool kubeconform)"

REPORT_DIR="${ROOT_DIR}/reports/k8s"
mkdir -p "${REPORT_DIR}"
ERRORS=0

check() {   # check <condición verdadera> <mensaje de error>
    if [[ "$1" != "true" ]]; then
        printf '[k8s][ERROR] %s\n' "$2" >&2
        ERRORS=$((ERRORS + 1))
    fi
}

# yq sin retornos de carro (yq.exe en Windows).
q() { "${YQ}" e -N "$1" "$2" | tr -d '\r'; }

to_gi() {   # 512Mi -> 0.5, 4Gi -> 4
    case "$1" in
        *Gi) printf '%s' "${1%Gi}" ;;
        *Mi) awk -v v="${1%Mi}" 'BEGIN { printf "%g", v / 1024 }' ;;
        *) fail "Unidad de almacenamiento no soportada: $1 (usa Mi o Gi)." ;;
    esac
}

# --- 1. Copia de init-db.sql -------------------------------------------------
if diff -q <(tr -d '\r' < "${ROOT_DIR}/init-db.sql") <(tr -d '\r' < "${K8S_DIR}/base/middleware/init-db.sql") >/dev/null; then
    ok "init-db.sql de Kubernetes es igual al de la raíz."
else
    check false "deploy/k8s/base/middleware/init-db.sql difiere de /init-db.sql. Cópialo de nuevo."
fi

# --- 2. Credenciales en texto plano ------------------------------------------
SECRET_PATTERN='(AKIA|ASIA)[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(PASSWORD|SECRET|TOKEN)[A-Z_]*[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9+/]{6,}'
FILES_SCANNED=$(find "${K8S_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sql' \) | wc -l | tr -d ' ')
if find "${K8S_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sql' \) -print0 \
        | xargs -0 grep -nE "${SECRET_PATTERN}" >/dev/null 2>&1; then
    find "${K8S_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sql' \) -print0 \
        | xargs -0 grep -lE "${SECRET_PATTERN}" | sed 's/^/[k8s][ERROR]   posible credencial en: /' >&2
    check false "Hay posibles credenciales en texto plano en deploy/k8s."
else
    ok "Sin credenciales en texto plano: manifiestos (${FILES_SCANNED} archivos)."
fi

# Imagen de referencia de cada componente: la de deploy/compose (US-08).
declare -A COMPOSE_IMAGE
for svc in "${MIDDLEWARE[@]}"; do
    COMPOSE_IMAGE[${svc}]="$(q ".services.${svc}.image" "${ROOT_DIR}/deploy/compose/docker-compose.prod.yml")"
    for env_file in dev stage; do
        other="$(q ".services.${svc}.image" "${ROOT_DIR}/deploy/compose/docker-compose.${env_file}.yml")"
        [[ "${other}" == "${COMPOSE_IMAGE[${svc}]}" ]] || warn "Compose ${env_file} usa ${other} para ${svc} y prod usa ${COMPOSE_IMAGE[${svc}]}."
    done
done

# --- 3. Cada overlay ---------------------------------------------------------
for env in "${ENVS[@]}"; do
    ns="$(namespace_for "${env}")"
    out="${REPORT_DIR}/${env}.yaml"
    before=${ERRORS}

    "${KUBECTL}" kustomize "${K8S_DIR}/overlays/${env}" > "${out}" \
        || { check false "Kustomize no pudo generar el overlay ${env}."; continue; }
    total="$(q 'select(.kind != null) | .kind' "${out}" | wc -l | tr -d ' ')"

    # CA2: namespace del ambiente.
    check "$([[ "$(q 'select(.kind == "Namespace") | .metadata.name' "${out}")" == "${ns}" ]] && echo true)" \
        "${env}: el overlay debe crear exactamente el Namespace ${ns}."
    check "$([[ "$(q 'select(.kind == "Namespace") | .metadata.labels["circleguard.io/environment"]' "${out}")" == "${env}" ]] && echo true)" \
        "${env}: el Namespace no tiene la etiqueta circleguard.io/environment=${env}."
    check "$([[ "$(q 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "${out}")" == "baseline" ]] && echo true)" \
        "${env}: el Namespace debe aplicar Pod Security baseline."
    outside="$(q "select(.kind != null and .kind != \"Namespace\" and .metadata.namespace != \"${ns}\") | .kind + \"/\" + .metadata.name" "${out}")"
    check "$([[ -z "${outside}" ]] && echo true)" "${env}: recursos fuera de ${ns}: ${outside//$'\n'/, }"
    for kind_name in ResourceQuota/environment-quota LimitRange/container-defaults \
                     NetworkPolicy/default-deny-ingress NetworkPolicy/allow-same-namespace; do
        found="$(q "select(.kind == \"${kind_name%/*}\" and .metadata.name == \"${kind_name#*/}\") | .metadata.name" "${out}")"
        check "$([[ -n "${found}" ]] && echo true)" "${env}: falta ${kind_name}."
    done
    deny_selector="$(q 'select(.kind == "NetworkPolicy" and .metadata.name == "default-deny-ingress") | .spec.podSelector | length' "${out}")"
    check "$([[ "${deny_selector}" == "0" ]] && echo true)" "${env}: default-deny-ingress debe aplicar a todos los pods (podSelector vacío)."

    # CA3: middleware completo y (US-37) los 8 microservicios.
    expected="$(printf '%s\n' "${MIDDLEWARE[@]}" | sort | tr '\n' ' ')"
    expected_apps="$(printf '%s\n' "${SERVICES[@]}" | sort | tr '\n' ' ')"
    expected_svcs="$(printf '%s\n' "${MIDDLEWARE[@]}" "${SERVICES[@]}" | sort | tr '\n' ' ')"
    sts="$(q 'select(.kind == "StatefulSet") | .metadata.name' "${out}" | sort | tr '\n' ' ')"
    deps="$(q 'select(.kind == "Deployment") | .metadata.name' "${out}" | sort | tr '\n' ' ')"
    svcs="$(q 'select(.kind == "Service") | .metadata.name' "${out}" | sort | tr '\n' ' ')"
    check "$([[ "${sts}" == "${expected}" ]] && echo true)" "${env}: StatefulSets esperados: ${expected}; encontrados: ${sts}"
    check "$([[ "${deps}" == "${expected_apps}" ]] && echo true)" "${env}: Deployments esperados: ${expected_apps}; encontrados: ${deps}"
    check "$([[ "${svcs}" == "${expected_svcs}" ]] && echo true)" "${env}: Services esperados: ${expected_svcs}; encontrados: ${svcs}"

    # Exposición: un solo Ingress (circleguard-api, host del ambiente) que apunta solo a
    # microservicios; ni LoadBalancer, ni NodePort, ni red del host.
    exposed="$(q 'select(.kind == "Service" and (.spec.type // "ClusterIP") != "ClusterIP") | .kind + "/" + .metadata.name' "${out}")"
    check "$([[ -z "${exposed}" ]] && echo true)" "${env}: ningún Service debe exponerse fuera del clúster: ${exposed}"
    ingresses="$(q 'select(.kind == "Ingress") | .metadata.name + "@" + .spec.rules[0].host' "${out}" | tr '\n' ' ')"
    check "$([[ "${ingresses}" == "circleguard-api@api.${env}.circleguard.edu " ]] && echo true)" \
        "${env}: se espera solo el Ingress circleguard-api con host api.${env}.circleguard.edu; encontrados: ${ingresses}"
    backends="$(q 'select(.kind == "Ingress") | .spec.rules[].http.paths[].backend.service.name' "${out}" | sort -u | tr '\n' ' ')"
    # notification-service no tiene API pública y web-client solo se usa por port-forward (E2E).
    internal=" notification-service web-client "
    for b in ${backends}; do
        check "$([[ " ${SERVICES[*]} " == *" ${b} "* && "${internal}" != *" ${b} "* ]] && echo true)" "${env}: el Ingress no debe publicar ${b}."
    done
    check "$([[ "$(wc -w <<< "${backends}" | tr -d ' ')" == "$(( ${#SERVICES[@]} - $(wc -w <<< "${internal}") ))" ]] && echo true)" \
        "${env}: el Ingress debe publicar los microservicios con API (todos menos${internal% }): ${backends}"
    risky="$(q 'select(.kind == "StatefulSet" or .kind == "Deployment") | select(.spec.template.spec.hostNetwork == true or .spec.template.spec.hostPID == true or ([.spec.template.spec.volumes[]? | select(has("hostPath"))] | length) > 0 or ([.spec.template.spec.containers[].securityContext.privileged] | any)) | .metadata.name' "${out}")"
    check "$([[ -z "${risky}" ]] && echo true)" "${env}: pods con hostNetwork, hostPID, hostPath o privileged: ${risky}"

    # Secretos: ninguno en Git y ninguna contraseña como valor literal.
    secrets_in_render="$(q 'select(.kind == "Secret") | .metadata.name' "${out}")"
    check "$([[ -z "${secrets_in_render}" ]] && echo true)" "${env}: el render incluye Secrets (${secrets_in_render}); deben crearse con create-secrets.sh."
    secret_refs="$(q '.. | select(tag == "!!map" and has("secretKeyRef")) | .secretKeyRef.name' "${out}" | sort -u | tr '\n' ' ')"
    check "$([[ "${secret_refs}" == "${APP_SECRET_NAME} ${SECRET_NAME} " ]] && echo true)" \
        "${env}: las contraseñas deben salir solo de ${APP_SECRET_NAME} y ${SECRET_NAME}; referencias: ${secret_refs}"
    literal="$(q 'select(.kind == "StatefulSet" or .kind == "Deployment") | .spec.template.spec.containers[].env[]? | select(has("value") and (.name | test("PASSWORD|SECRET|TOKEN|AUTH"))) | .name' "${out}")"
    check "$([[ -z "${literal}" ]] && echo true)" "${env}: variables sensibles con valor literal: ${literal}"

    # US-26: RBAC. Una cuenta por microservicio, ninguna con token, y el Role de Jenkins
    # sin comodines, sin Secrets ni pods/exec. Nada a nivel de clúster.
    sa_mismatch="$(q 'select(.kind == "Deployment" and .spec.template.spec.serviceAccountName != .metadata.name) | .metadata.name' "${out}")"
    check "$([[ -z "${sa_mismatch}" ]] && echo true)" "${env}: estos Deployments deben usar la cuenta de servicio con su nombre: ${sa_mismatch}"
    sa_token="$(q 'select(.kind == "ServiceAccount" and .automountServiceAccountToken != false) | .metadata.name' "${out}")"
    check "$([[ -z "${sa_token}" ]] && echo true)" "${env}: cuentas de servicio que montan token: ${sa_token}"
    cluster_rbac="$(q 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .metadata.name' "${out}")"
    check "$([[ -z "${cluster_rbac}" ]] && echo true)" "${env}: el overlay no debe crear RBAC de clúster: ${cluster_rbac}"
    role_rules="$(q 'select(.kind == "Role" and .metadata.name == "jenkins-deployer") | .rules[] | (.resources + .verbs + .apiGroups)[]' "${out}")"
    check "$([[ -n "${role_rules}" ]] && echo true)" "${env}: falta el Role jenkins-deployer."
    check "$(grep -qxE '\*|secrets|pods/exec|pods/attach|escalate|bind|impersonate' <<< "${role_rules}" || echo true)" \
        "${env}: el Role jenkins-deployer no debe usar comodines ni dar Secrets, pods/exec, pods/attach, escalate, bind o impersonate."

    # Contenedores: imagen fija e igual a compose, probes y recursos.
    while IFS='|' read -r owner container image ready live rcpu rmem lcpu lmem links token; do
        [[ -n "${owner}" ]] || continue
        tag="${image##*:}"
        check "$([[ "${image}" == *:* && "${tag}" != "latest" && "${image}" != *@* || "${image}" == *@sha256:* ]] && echo true)" \
            "${env}: ${owner}/${container} usa una imagen sin versión fija: ${image}"
        check "$([[ "${image}" == "${COMPOSE_IMAGE[${owner}]:-}" ]] && echo true)" \
            "${env}: ${owner} usa ${image} y deploy/compose usa ${COMPOSE_IMAGE[${owner}]:-<ninguna>}."
        check "$([[ "${ready}" == "true" && "${live}" == "true" ]] && echo true)" "${env}: ${owner}/${container} necesita readinessProbe y livenessProbe."
        check "$([[ -n "${rcpu}" && -n "${rmem}" && -n "${lcpu}" && -n "${lmem}" ]] && echo true)" \
            "${env}: ${owner}/${container} necesita requests y limits de CPU y memoria."
        check "$([[ "${links}" == "false" ]] && echo true)" "${env}: ${owner} debe declarar enableServiceLinks: false."
        check "$([[ "${token}" == "false" ]] && echo true)" "${env}: ${owner} no debe montar el token de la cuenta de servicio."
    done < <(q 'select(.kind == "StatefulSet") | .metadata.name as $o | .spec.template.spec as $p | $p.containers[] |
        [$o, .name, .image, (has("readinessProbe") | tostring), (has("livenessProbe") | tostring),
         (.resources.requests.cpu // ""), (.resources.requests.memory // ""),
         (.resources.limits.cpu // ""), (.resources.limits.memory // ""),
         ($p.enableServiceLinks | tostring), ($p.automountServiceAccountToken | tostring)] | join("|")' "${out}")

    # US-37: microservicios con imagen versionada, recursos y contenedor endurecido.
    while IFS='|' read -r owner image rcpu rmem lcpu lmem links token nonroot rofs; do
        [[ -n "${owner}" ]] || continue
        check "$([[ "${image}" =~ ^circleguard/${owner}:[0-9]+\.[0-9]+\.[0-9]+ ]] && echo true)" \
            "${env}: ${owner} debe usar circleguard/${owner}:<X.Y.Z> (k8s-deploy.sh fija registro y versión): ${image}"
        check "$([[ -n "${rcpu}" && -n "${rmem}" && -n "${lcpu}" && -n "${lmem}" ]] && echo true)" \
            "${env}: ${owner} necesita requests y limits de CPU y memoria."
        check "$([[ "${links}|${token}|${nonroot}|${rofs}" == "false|false|true|true" ]] && echo true)" \
            "${env}: ${owner} debe tener enableServiceLinks y token en false, runAsNonRoot y readOnlyRootFilesystem."
    done < <(q 'select(.kind == "Deployment") | .metadata.name as $o | .spec.template.spec as $p | $p.containers[] |
        [$o, .image, (.resources.requests.cpu // ""), (.resources.requests.memory // ""),
         (.resources.limits.cpu // ""), (.resources.limits.memory // ""),
         ($p.enableServiceLinks | tostring), ($p.automountServiceAccountToken | tostring),
         ($p.securityContext.runAsNonRoot | tostring), (.securityContext.readOnlyRootFilesystem | tostring)] | join("|")' "${out}")

    # Almacenamiento: los volúmenes (StatefulSets y PVC sueltos) deben caber en la cuota.
    pvc_total=0
    while read -r size; do
        [[ -n "${size}" ]] && pvc_total="$(awk -v a="${pvc_total}" -v b="$(to_gi "${size}")" 'BEGIN { printf "%g", a + b }')"
    done < <(q 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[].spec.resources.requests.storage' "${out}"
             q 'select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage' "${out}")
    quota_storage="$(q 'select(.kind == "ResourceQuota") | .spec.hard["requests.storage"]' "${out}")"
    check "$(awk -v a="${pvc_total}" -v b="$(to_gi "${quota_storage}")" 'BEGIN { print (a <= b) ? "true" : "false" }')" \
        "${env}: los volúmenes piden ${pvc_total} Gi y la cuota es ${quota_storage}."

    # Esquema de Kubernetes.
    if [[ -n "${KUBECONFORM}" ]]; then
        if schema_out="$("${KUBECONFORM}" -strict -summary -output text "${out}" 2>&1)"; then
            ok "${env}: esquema válido (${schema_out//$'\n'/ })."
        else
            printf '%s\n' "${schema_out}" >&2
            check false "${env}: kubeconform encontró recursos inválidos."
        fi
    fi

    {
        printf 'Ambiente: %s\nNamespace: %s\nRecursos: %s\n\n' "${env}" "${ns}" "${total}"
        q 'select(.kind != null) | .kind' "${out}" | sort | uniq -c
        printf '\nContenedor | imagen | requests | limits\n'
        q 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | .name + " | " + .image + " | " + .resources.requests.cpu + "/" + .resources.requests.memory + " | " + .resources.limits.cpu + "/" + .resources.limits.memory' "${out}"
        printf '\nVolúmenes: %s Gi (cuota %s)\n' "${pvc_total}" "${quota_storage}"
    } > "${REPORT_DIR}/${env}-summary.txt"

    if [[ ${ERRORS} -eq ${before} ]]; then
        ok "Ambiente ${env}: ${total} recursos en ${ns}; middleware y ${#SERVICES[@]} microservicios completos; volúmenes ${pvc_total} Gi de ${quota_storage}."
    fi
done

[[ ${ERRORS} -eq 0 ]] || fail "Validación de Kubernetes con ${ERRORS} error(es)."
ok "Validación de Kubernetes completada para: ${ENVS[*]}."
