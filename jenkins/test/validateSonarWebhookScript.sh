#!/usr/bin/env bash
# =============================================================================
# jenkins/test/validateSonarWebhookScript.sh
# Historia de Usuario: US-10 (SCRUM-22 / SCRUM-58) — CA2 y CA3
#
# Valida de forma reproducible y sin red que jenkins/ci/setup-sonarqube-quality-gate.sh:
#   1. Tiene sintaxis Bash válida.
#   2. En --dry-run genera el plan JSON con Quality Gate (>= 60%), condiciones
#      de cobertura/seguridad/fiabilidad/mantenibilidad y webhook /sonarqube-webhook/
#      enmascarando el secreto HMAC.
#   3. Con curl simulado, la primera ejecución crea el proyecto, el Quality Gate,
#      las condiciones (>= 60%) y el webhook, y la segunda ejecución actualiza
#      las condiciones y el webhook existente de forma idempotente.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_SCRIPT="${REPO_ROOT}/jenkins/ci/setup-sonarqube-quality-gate.sh"

echo "=== Validacion del script de SonarQube Quality Gate y Webhook (US-10 / CA3) ==="

bash -n "${TARGET_SCRIPT}"
echo "[OK] Sintaxis Bash valida."

SECRET_VALUE="sonar-hmac-secret-dont-leak-987654"
DRY_OUTPUT="$(
    SONAR_WEBHOOK_SECRET="${SECRET_VALUE}" \
    JENKINS_URL="http://18.117.90.15:8080" \
    SONAR_HOST_URL="http://localhost:9000" \
    bash "${TARGET_SCRIPT}" --dry-run
)"

[[ "${DRY_OUTPUT}" == *"[DRY-RUN]"* ]] || { echo "Fallo: falta marca DRY-RUN"; exit 1; }
[[ "${DRY_OUTPUT}" == *"http://18.117.90.15:8080/sonarqube-webhook/"* ]] || { echo "Fallo: URL de webhook incorrecta"; exit 1; }
[[ "${DRY_OUTPUT}" == *"\"metric\": \"coverage\""* ]] || { echo "Fallo: falta condicion coverage"; exit 1; }
[[ "${DRY_OUTPUT}" == *"\"error\": \"60\""* ]] || { echo "Fallo: falta umbral 60%"; exit 1; }
[[ "${DRY_OUTPUT}" == *"\"secret\": \"***\""* ]] || { echo "Fallo: secreto no enmascarado"; exit 1; }
if [[ "${DRY_OUTPUT}" == *"${SECRET_VALUE}"* ]]; then
    echo "Fallo: el secreto en texto plano se imprimio en dry-run"
    exit 1
fi
echo "[OK] Dry-run construye Quality Gate (>= 60%), webhook /sonarqube-webhook/ y enmascara el secreto."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

STATE_FILE="${TMP_DIR}/sonar_state.json"
CALLS_LOG="${TMP_DIR}/curl_calls.log"
cat <<'EOF' > "${STATE_FILE}"
{"project_exists": false, "gate_exists": false, "conditions": [], "webhook_exists": false}
EOF
: > "${CALLS_LOG}"

cat <<'EOF' > "${TMP_DIR}/curl"
#!/usr/bin/env bash
set -euo pipefail
URL="${@: -1}"
echo "$*" >> "${MOCK_CALLS_LOG}"

python3 - "${URL}" "${MOCK_STATE_FILE}" "$@" <<'PY'
import json
import sys
import urllib.parse

url = sys.argv[1]
state_file = sys.argv[2]
args = sys.argv[3:]

with open(state_file, "r", encoding="utf-8") as fh:
    state = json.load(fh)

params = {}
for i, token in enumerate(args):
    if token == "--data-urlencode" and i + 1 < len(args):
        kv = args[i + 1]
        if "=" in kv:
            k, v = kv.split("=", 1)
            params[k] = v

if "/api/projects/search" in url:
    comps = [{"key": "circleguard-monorepo", "name": "CircleGuard Monorepo"}] if state["project_exists"] else []
    print(json.dumps({"components": comps}))
elif "/api/projects/create" in url:
    state["project_exists"] = True
    print(json.dumps({"project": {"key": params.get("project", "circleguard-monorepo")}}))
elif "/api/qualitygates/list" in url:
    gates = [{"name": "CircleGuard-Quality-Gate"}] if state["gate_exists"] else []
    print(json.dumps({"qualitygates": gates}))
elif "/api/qualitygates/create_condition" in url:
    cond_id = str(len(state["conditions"]) + 1)
    state["conditions"].append({
        "id": cond_id,
        "metric": params.get("metric", ""),
        "op": params.get("op", ""),
        "error": params.get("error", ""),
    })
    print(json.dumps({"id": cond_id}))
elif "/api/qualitygates/update_condition" in url:
    print(json.dumps({"id": params.get("id", "1")}))
elif "/api/qualitygates/create" in url:
    state["gate_exists"] = True
    print(json.dumps({"name": params.get("name", "CircleGuard-Quality-Gate")}))
elif "/api/qualitygates/show" in url:
    print(json.dumps({"name": "CircleGuard-Quality-Gate", "conditions": state["conditions"]}))
elif "/api/qualitygates/select" in url:
    print("{}")
elif "/api/webhooks/list" in url:
    hooks = [{"key": "wh-101", "name": "jenkins-sonarqube-webhook", "url": "http://18.117.90.15:8080/sonarqube-webhook/"}] if state["webhook_exists"] else []
    print(json.dumps({"webhooks": hooks}))
elif "/api/webhooks/create" in url:
    state["webhook_exists"] = True
    print(json.dumps({"webhook": {"key": "wh-101", "name": params.get("name", "")}}))
elif "/api/webhooks/update" in url:
    print("{}")
else:
    print("{}")

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(state, fh)
PY
EOF
chmod +x "${TMP_DIR}/curl"

RUN1_OUT="$(
    PATH="${TMP_DIR}:${PATH}" \
    MOCK_STATE_FILE="${STATE_FILE}" \
    MOCK_CALLS_LOG="${CALLS_LOG}" \
    SONAR_TOKEN="squ_test_token_123" \
    SONAR_WEBHOOK_SECRET="${SECRET_VALUE}" \
    JENKINS_URL="http://18.117.90.15:8080" \
    SONAR_HOST_URL="http://localhost:9000" \
    bash "${TARGET_SCRIPT}"
)"

[[ "${RUN1_OUT}" == *"circleguard-monorepo (creado)"* ]] || { echo "Fallo run1 proyecto: ${RUN1_OUT}"; exit 1; }
[[ "${RUN1_OUT}" == *"CircleGuard-Quality-Gate (creado, cobertura >= 60%)"* ]] || { echo "Fallo run1 gate: ${RUN1_OUT}"; exit 1; }
[[ "${RUN1_OUT}" == *"Webhook      : creado (key=wh-101"* ]] || { echo "Fallo run1 webhook: ${RUN1_OUT}"; exit 1; }
if [[ "${RUN1_OUT}" == *"${SECRET_VALUE}"* ]]; then
    echo "Fallo: el secreto se filtro en la salida de ejecucion"
    exit 1
fi

RUN2_OUT="$(
    PATH="${TMP_DIR}:${PATH}" \
    MOCK_STATE_FILE="${STATE_FILE}" \
    MOCK_CALLS_LOG="${CALLS_LOG}" \
    SONAR_TOKEN="squ_test_token_123" \
    SONAR_WEBHOOK_SECRET="${SECRET_VALUE}" \
    JENKINS_URL="http://18.117.90.15:8080" \
    SONAR_HOST_URL="http://localhost:9000" \
    bash "${TARGET_SCRIPT}"
)"

[[ "${RUN2_OUT}" == *"circleguard-monorepo (existente)"* ]] || { echo "Fallo run2 proyecto: ${RUN2_OUT}"; exit 1; }
[[ "${RUN2_OUT}" == *"CircleGuard-Quality-Gate (actualizado, cobertura >= 60%)"* ]] || { echo "Fallo run2 gate: ${RUN2_OUT}"; exit 1; }
[[ "${RUN2_OUT}" == *"Webhook      : actualizado (key=wh-101"* ]] || { echo "Fallo run2 webhook: ${RUN2_OUT}"; exit 1; }

grep -q "/api/qualitygates/create_condition" "${CALLS_LOG}" || { echo "Fallo: no se llamo create_condition"; exit 1; }
grep -q "/api/qualitygates/update_condition" "${CALLS_LOG}" || { echo "Fallo: no se llamo update_condition en segunda pasada"; exit 1; }
grep -q "/api/webhooks/create" "${CALLS_LOG}" || { echo "Fallo: no se llamo webhooks/create"; exit 1; }
grep -q "/api/webhooks/update" "${CALLS_LOG}" || { echo "Fallo: no se llamo webhooks/update"; exit 1; }

echo "[OK] Primera ejecucion crea (POST) y segunda actualiza condiciones y webhook sin duplicar."
echo "=== VALIDACION DE SONARQUBE QUALITY GATE Y WEBHOOK COMPLETADA ==="
