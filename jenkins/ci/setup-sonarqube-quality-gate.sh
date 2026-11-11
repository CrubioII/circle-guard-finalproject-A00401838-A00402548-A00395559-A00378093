#!/usr/bin/env bash
# =============================================================================
# jenkins/ci/setup-sonarqube-quality-gate.sh
# Historia de Usuario: US-10 (SCRUM-22 / SCRUM-58)
#
# Configura de forma idempotente en SonarQube:
#   1. El proyecto 'circleguard-monorepo' (si no existe).
#   2. El Quality Gate personalizado 'CircleGuard-Quality-Gate' con umbral
#      bloqueante de cobertura >= 60% (coverage < 60 -> ERROR, new_coverage < 60 -> ERROR).
#   3. El webhook de retorno hacia Jenkins (<JENKINS_URL>/sonarqube-webhook/)
#      para que waitForQualityGate(abortPipeline: true) reciba el resultado.
# =============================================================================

set -euo pipefail

SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}"
SONAR_TOKEN="${SONAR_TOKEN:-}"
JENKINS_URL="${JENKINS_URL:-}"
SONAR_WEBHOOK_SECRET="${SONAR_WEBHOOK_SECRET:-}"
PROJECT_KEY="${SONAR_PROJECT_KEY:-circleguard-monorepo}"
PROJECT_NAME="${SONAR_PROJECT_NAME:-CircleGuard Monorepo}"
QUALITY_GATE_NAME="${SONAR_QUALITY_GATE_NAME:-CircleGuard-Quality-Gate}"
MIN_COVERAGE="${SONAR_MIN_COVERAGE:-60}"
WEBHOOK_NAME="${SONAR_WEBHOOK_NAME:-jenkins-sonarqube-webhook}"
DRY_RUN=false

usage() {
    cat <<'EOF'
Configura el Quality Gate (>= 60% cobertura) y el webhook hacia Jenkins en SonarQube.

Uso:
  SONAR_TOKEN=squ_... JENKINS_URL=http://jenkins:8080 ./jenkins/ci/setup-sonarqube-quality-gate.sh [opciones]

Opciones:
  --dry-run                Muestra la configuración (con secretos enmascarados) sin llamar a SonarQube.
  --sonar-url <url>        URL base de SonarQube (por defecto SONAR_HOST_URL o http://localhost:9000).
  --jenkins-url <url>      URL base de Jenkins para el webhook /sonarqube-webhook/.
  --project-key <key>      Clave del proyecto en SonarQube (por defecto circleguard-monorepo).
  --gate-name <name>       Nombre del Quality Gate (por defecto CircleGuard-Quality-Gate).
  --min-coverage <pct>     Umbral mínimo de cobertura en porcentaje (por defecto 60).
  -h, --help               Muestra esta ayuda.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --sonar-url)
            SONAR_HOST_URL="${2:-}"
            shift 2
            ;;
        --jenkins-url)
            JENKINS_URL="${2:-}"
            shift 2
            ;;
        --project-key)
            PROJECT_KEY="${2:-}"
            shift 2
            ;;
        --gate-name)
            QUALITY_GATE_NAME="${2:-}"
            shift 2
            ;;
        --min-coverage)
            MIN_COVERAGE="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: opción desconocida '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: se requiere python3 para procesar las respuestas JSON de SonarQube." >&2
    exit 1
fi

if [[ -z "${JENKINS_URL}" ]]; then
    echo "ERROR: define JENKINS_URL (o usa --jenkins-url)." >&2
    exit 1
fi

if [[ ! "${JENKINS_URL}" =~ ^https?:// ]]; then
    echo "ERROR: JENKINS_URL debe iniciar con http:// o https://." >&2
    exit 1
fi

if [[ ! "${SONAR_HOST_URL}" =~ ^https?:// ]]; then
    echo "ERROR: SONAR_HOST_URL debe iniciar con http:// o https://." >&2
    exit 1
fi

if [[ ! "${MIN_COVERAGE}" =~ ^[0-9]+$ ]] || (( MIN_COVERAGE < 1 || MIN_COVERAGE > 100 )); then
    echo "ERROR: --min-coverage debe ser un entero entre 1 y 100 (actual: '${MIN_COVERAGE}')." >&2
    exit 1
fi

SONAR_BASE="${SONAR_HOST_URL%/}"
JENKINS_BASE="${JENKINS_URL%/}"
if [[ "${JENKINS_BASE}" == */sonarqube-webhook ]]; then
    WEBHOOK_URL="${JENKINS_BASE}/"
else
    WEBHOOK_URL="${JENKINS_BASE}/sonarqube-webhook/"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    SECRET_STATUS="no configurado"
    if [[ -n "${SONAR_WEBHOOK_SECRET}" ]]; then
        SECRET_STATUS="***"
    fi
    PLAN_JSON="$(
        SONAR_BASE="${SONAR_BASE}" \
        PROJECT_KEY="${PROJECT_KEY}" \
        PROJECT_NAME="${PROJECT_NAME}" \
        QUALITY_GATE_NAME="${QUALITY_GATE_NAME}" \
        MIN_COVERAGE="${MIN_COVERAGE}" \
        WEBHOOK_NAME="${WEBHOOK_NAME}" \
        WEBHOOK_URL="${WEBHOOK_URL}" \
        SECRET_STATUS="${SECRET_STATUS}" \
        python3 -c '
import json
import os

min_cov = os.environ["MIN_COVERAGE"]
print(json.dumps({
    "sonarUrl": os.environ["SONAR_BASE"],
    "project": {
        "key": os.environ["PROJECT_KEY"],
        "name": os.environ["PROJECT_NAME"],
    },
    "qualityGate": {
        "name": os.environ["QUALITY_GATE_NAME"],
        "conditions": [
            {"metric": "coverage", "op": "LT", "error": min_cov},
            {"metric": "new_coverage", "op": "LT", "error": min_cov},
            {"metric": "new_security_rating", "op": "GT", "error": "1"},
            {"metric": "new_reliability_rating", "op": "GT", "error": "1"},
            {"metric": "new_maintainability_rating", "op": "GT", "error": "1"},
        ],
    },
    "webhook": {
        "name": os.environ["WEBHOOK_NAME"],
        "url": os.environ["WEBHOOK_URL"],
        "secret": os.environ["SECRET_STATUS"],
    },
}, indent=2, ensure_ascii=False))
'
    )"
    cat <<EOF
[DRY-RUN] No se modificó SonarQube.
SonarQube   : ${SONAR_BASE}
Proyecto    : ${PROJECT_KEY}
Quality Gate: ${QUALITY_GATE_NAME} (cobertura >= ${MIN_COVERAGE}%)
Webhook URL : ${WEBHOOK_URL}
Plan JSON   :
${PLAN_JSON}
EOF
    exit 0
fi

if [[ -z "${SONAR_TOKEN}" ]]; then
    echo "ERROR: exporta SONAR_TOKEN con permisos de administración en SonarQube." >&2
    exit 1
fi

AUTH_HEADER="Authorization: Bearer ${SONAR_TOKEN}"

sonar_get() {
    local path="$1"
    curl -fsSL -H "${AUTH_HEADER}" "${SONAR_BASE}${path}"
}

sonar_post() {
    local path="$1"
    shift
    curl -fsSL -X POST -H "${AUTH_HEADER}" "$@" "${SONAR_BASE}${path}"
}

# 1. Crear proyecto si no existe
PROJECTS_JSON="$(sonar_get "/api/projects/search?projects=${PROJECT_KEY}")"
PROJECT_EXISTS="$(PROJECTS_JSON="${PROJECTS_JSON}" PROJECT_KEY="${PROJECT_KEY}" python3 -c '
import json, os
data = json.loads(os.environ.get("PROJECTS_JSON", "{}"))
comps = data.get("components", [])
print("true" if any(c.get("key") == os.environ["PROJECT_KEY"] for c in comps) else "false")
')"

if [[ "${PROJECT_EXISTS}" != "true" ]]; then
    sonar_post "/api/projects/create" \
        --data-urlencode "project=${PROJECT_KEY}" \
        --data-urlencode "name=${PROJECT_NAME}" >/dev/null
    PROJECT_ACTION="creado"
else
    PROJECT_ACTION="existente"
fi

# 2. Crear o reutilizar el Quality Gate
GATES_JSON="$(sonar_get "/api/qualitygates/list")"
GATE_EXISTS="$(GATES_JSON="${GATES_JSON}" QUALITY_GATE_NAME="${QUALITY_GATE_NAME}" python3 -c '
import json, os
data = json.loads(os.environ.get("GATES_JSON", "{}"))
gates = data.get("qualitygates", [])
print("true" if any(g.get("name") == os.environ["QUALITY_GATE_NAME"] for g in gates) else "false")
')"

if [[ "${GATE_EXISTS}" != "true" ]]; then
    sonar_post "/api/qualitygates/create" \
        --data-urlencode "name=${QUALITY_GATE_NAME}" >/dev/null
    GATE_ACTION="creado"
else
    GATE_ACTION="actualizado"
fi

# 3. Sincronizar condiciones del Quality Gate (idempotente)
GATE_SHOW_JSON="$(sonar_get "/api/qualitygates/show?name=${QUALITY_GATE_NAME}")"

upsert_condition() {
    local metric="$1"
    local op="$2"
    local error_val="$3"
    local existing_id
    existing_id="$(GATE_SHOW_JSON="${GATE_SHOW_JSON}" METRIC="${metric}" python3 -c '
import json, os
data = json.loads(os.environ.get("GATE_SHOW_JSON", "{}"))
for cond in data.get("conditions", []):
    if cond.get("metric") == os.environ["METRIC"]:
        print(cond.get("id", ""))
        break
')"
    if [[ -n "${existing_id}" ]]; then
        sonar_post "/api/qualitygates/update_condition" \
            --data-urlencode "id=${existing_id}" \
            --data-urlencode "metric=${metric}" \
            --data-urlencode "op=${op}" \
            --data-urlencode "error=${error_val}" >/dev/null
    else
        sonar_post "/api/qualitygates/create_condition" \
            --data-urlencode "gateName=${QUALITY_GATE_NAME}" \
            --data-urlencode "metric=${metric}" \
            --data-urlencode "op=${op}" \
            --data-urlencode "error=${error_val}" >/dev/null
    fi
}

upsert_condition "coverage" "LT" "${MIN_COVERAGE}"
upsert_condition "new_coverage" "LT" "${MIN_COVERAGE}"
upsert_condition "new_security_rating" "GT" "1"
upsert_condition "new_reliability_rating" "GT" "1"
upsert_condition "new_maintainability_rating" "GT" "1"

# Asociar el Quality Gate al proyecto
sonar_post "/api/qualitygates/select" \
    --data-urlencode "projectKey=${PROJECT_KEY}" \
    --data-urlencode "gateName=${QUALITY_GATE_NAME}" >/dev/null

# 4. Crear o actualizar el webhook de retorno hacia Jenkins
WEBHOOKS_JSON="$(sonar_get "/api/webhooks/list?project=${PROJECT_KEY}")"
WEBHOOK_KEY="$(WEBHOOKS_JSON="${WEBHOOKS_JSON}" WEBHOOK_URL="${WEBHOOK_URL}" WEBHOOK_NAME="${WEBHOOK_NAME}" python3 -c '
import json, os
data = json.loads(os.environ.get("WEBHOOKS_JSON", "{}"))
hooks = data.get("webhooks", [])
for hook in hooks:
    if hook.get("url") == os.environ["WEBHOOK_URL"] or hook.get("name") == os.environ["WEBHOOK_NAME"]:
        print(hook.get("key", ""))
        break
')"

WEBHOOK_ARGS=(
    --data-urlencode "name=${WEBHOOK_NAME}"
    --data-urlencode "url=${WEBHOOK_URL}"
    --data-urlencode "project=${PROJECT_KEY}"
)
if [[ -n "${SONAR_WEBHOOK_SECRET}" ]]; then
    WEBHOOK_ARGS+=(--data-urlencode "secret=${SONAR_WEBHOOK_SECRET}")
fi

if [[ -n "${WEBHOOK_KEY}" ]]; then
    sonar_post "/api/webhooks/update" \
        --data-urlencode "webhook=${WEBHOOK_KEY}" \
        "${WEBHOOK_ARGS[@]}" >/dev/null
    WEBHOOK_ACTION="actualizado"
else
    RESPONSE_HOOK="$(sonar_post "/api/webhooks/create" "${WEBHOOK_ARGS[@]}")"
    WEBHOOK_KEY="$(RESPONSE_HOOK="${RESPONSE_HOOK}" python3 -c '
import json, os
data = json.loads(os.environ.get("RESPONSE_HOOK", "{}"))
print(data.get("webhook", {}).get("key", "creado"))
')"
    WEBHOOK_ACTION="creado"
fi

echo "[OK] SonarQube configurado para ${PROJECT_KEY} (${PROJECT_ACTION})."
echo "     Quality Gate : ${QUALITY_GATE_NAME} (${GATE_ACTION}, cobertura >= ${MIN_COVERAGE}%)"
echo "     Webhook      : ${WEBHOOK_ACTION} (key=${WEBHOOK_KEY}, url=${WEBHOOK_URL})"
if [[ -n "${SONAR_WEBHOOK_SECRET}" ]]; then
    echo "     Secreto HMAC : configurado (no se imprime)."
else
    echo "     Secreto HMAC : no configurado."
fi
