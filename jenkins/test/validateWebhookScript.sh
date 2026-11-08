#!/usr/bin/env bash
# =============================================================================
# jenkins/test/validateWebhookScript.sh
# Historia de Usuario: US-30 (SCRUM-113 / SCRUM-57) — CA3
#
# Valida de forma reproducible el script que registra el webhook de GitHub:
#   1. Sintaxis Bash.
#   2. Modo --dry-run: URL correcta, eventos y secreto enmascarado.
#   3. Idempotencia real con un `gh` falso: primera ejecución POST (crear),
#      segunda ejecución PATCH (actualizar el mismo hook).
#   4. El mismo comportamiento con el fallback `curl` (sin `gh` en el PATH).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_SCRIPT="${REPO_ROOT}/jenkins/ci/setup-github-webhook.sh"

echo "=== Validacion del webhook de GitHub (US-30 / CA3) ==="

if [[ ! -f "${SETUP_SCRIPT}" ]]; then
    echo "ERROR: no existe ${SETUP_SCRIPT}" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 es requerido para esta validacion." >&2
    exit 1
fi

bash -n "${SETUP_SCRIPT}"
echo "[OK] Sintaxis Bash valida."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${TMP_DIR}/bin"

export JENKINS_URL="https://ci.circleguard.example"
export WEBHOOK_SECRET="s3cr3t-super-secreto"
export GITHUB_TOKEN="dummy-token"
export GITHUB_REPOSITORY="CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093"

# -----------------------------------------------------------------------------
# 1. Dry-run: payload correcto, secreto nunca impreso
# -----------------------------------------------------------------------------
"${SETUP_SCRIPT}" --dry-run > "${TMP_DIR}/dry-run.out" 2>&1
grep -q 'https://ci.circleguard.example/github-webhook/' "${TMP_DIR}/dry-run.out"
grep -q '"pull_request"' "${TMP_DIR}/dry-run.out"
grep -q '"secret": "\*\*\*"' "${TMP_DIR}/dry-run.out"
if grep -q 's3cr3t-super-secreto' "${TMP_DIR}/dry-run.out"; then
    echo "ERROR: el dry-run expuso el secreto del webhook." >&2
    cat "${TMP_DIR}/dry-run.out" >&2
    exit 1
fi
echo "[OK] Dry-run construye el payload con eventos y enmascara el secreto."

# -----------------------------------------------------------------------------
# 2. `gh` falso para probar la idempotencia sin llamar a GitHub
# -----------------------------------------------------------------------------
cat > "${TMP_DIR}/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"

method="GET"
positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --method)
            method="${2:?}"
            shift 2
            ;;
        --paginate)
            shift
            ;;
        --input)
            shift 2
            ;;
        -*)
            shift
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

if [[ "${method}" == "GET" ]]; then
    if [[ -s "${FAKE_GH_STATE:?}" ]]; then
        cat "${FAKE_GH_STATE}"
    else
        printf '[]'
    fi
    exit 0
fi

PAYLOAD="$(cat)"
printf '%s' "${PAYLOAD}" > "${FAKE_GH_LAST_PAYLOAD:?}"

STATE_FILE="${FAKE_GH_STATE:?}" PAYLOAD="${PAYLOAD}" python3 -c '
import json
import os

state_file = os.environ["STATE_FILE"]
payload = json.loads(os.environ["PAYLOAD"])
with open(state_file, "w", encoding="utf-8") as handle:
    json.dump([{
        "id": 100,
        "config": {"url": payload["config"]["url"]},
        "events": payload["events"],
    }], handle)
'
printf '{"id":100}'
FAKE_GH
chmod +x "${TMP_DIR}/bin/gh"

export PATH="${TMP_DIR}/bin:${PATH}"
export FAKE_GH_LOG="${TMP_DIR}/gh-calls.log"
export FAKE_GH_STATE="${TMP_DIR}/gh-state.json"
export FAKE_GH_LAST_PAYLOAD="${TMP_DIR}/gh-last-payload.json"
: > "${FAKE_GH_LOG}"

"${SETUP_SCRIPT}" > "${TMP_DIR}/run-1.out" 2>&1
if ! grep -q '^api --method POST' "${FAKE_GH_LOG}"; then
    echo "ERROR: la primera ejecución debía crear el webhook con POST." >&2
    cat "${FAKE_GH_LOG}" >&2
    cat "${TMP_DIR}/run-1.out" >&2
    exit 1
fi
grep -q 'Webhook creado' "${TMP_DIR}/run-1.out"

"${SETUP_SCRIPT}" > "${TMP_DIR}/run-2.out" 2>&1
if ! grep -q '^api --method PATCH' "${FAKE_GH_LOG}"; then
    echo "ERROR: la segunda ejecución debía actualizar el webhook con PATCH." >&2
    cat "${FAKE_GH_LOG}" >&2
    cat "${TMP_DIR}/run-2.out" >&2
    exit 1
fi
grep -q 'Webhook actualizado' "${TMP_DIR}/run-2.out"

POST_COUNT="$(grep -c '^api --method POST' "${FAKE_GH_LOG}" || true)"
PATCH_COUNT="$(grep -c '^api --method PATCH' "${FAKE_GH_LOG}" || true)"
if [[ "${POST_COUNT}" -ne 1 || "${PATCH_COUNT}" -ne 1 ]]; then
    echo "ERROR: idempotencia incorrecta (POST=${POST_COUNT}, PATCH=${PATCH_COUNT})." >&2
    cat "${FAKE_GH_LOG}" >&2
    exit 1
fi

STATE_FILE="${FAKE_GH_STATE}" PAYLOAD_FILE="${FAKE_GH_LAST_PAYLOAD}" python3 -c '
import json
import os

state = json.load(open(os.environ["STATE_FILE"], encoding="utf-8"))
payload = json.load(open(os.environ["PAYLOAD_FILE"], encoding="utf-8"))

expected_url = "https://ci.circleguard.example/github-webhook/"
assert len(state) == 1, "Debe existir un unico webhook registrado"
assert state[0]["config"]["url"] == expected_url, "URL del webhook incorrecta"
assert payload["events"] == ["push", "pull_request", "create", "delete"], "Eventos incorrectos"
assert payload["config"]["secret"] == "s3cr3t-super-secreto", "El secreto no se envio en el payload"
assert payload["active"] is True, "El webhook debe quedar activo"
'
echo "[OK] Primera ejecucion crea (POST) y segunda actualiza (PATCH) el mismo webhook."
echo "[OK] El payload contiene los eventos push/pull_request/create/delete y el secreto configurado."

# -----------------------------------------------------------------------------
# 3. Fallback con `curl` cuando `gh` no está disponible
# -----------------------------------------------------------------------------
mkdir -p "${TMP_DIR}/curl-bin"
cat > "${TMP_DIR}/curl-bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"

method="GET"
data_ref=""
positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X)
            method="${2:?}"
            shift 2
            ;;
        --data)
            data_ref="${2:?}"
            shift 2
            ;;
        -H)
            shift 2
            ;;
        -*)
            shift
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

if [[ "${method}" == "GET" ]]; then
    if [[ -s "${FAKE_CURL_STATE:?}" ]]; then
        cat "${FAKE_CURL_STATE}"
    else
        printf '[]'
    fi
    exit 0
fi

if [[ "${data_ref}" == "@-" ]]; then
    PAYLOAD="$(cat)"
else
    PAYLOAD="$(cat "${data_ref}")"
fi

STATE_FILE="${FAKE_CURL_STATE:?}" PAYLOAD="${PAYLOAD}" python3 -c '
import json
import os

state_file = os.environ["STATE_FILE"]
payload = json.loads(os.environ["PAYLOAD"])
with open(state_file, "w", encoding="utf-8") as handle:
    json.dump([{
        "id": 200,
        "config": {"url": payload["config"]["url"]},
        "events": payload["events"],
    }], handle)
'
printf '{"id":200}'
FAKE_CURL
chmod +x "${TMP_DIR}/curl-bin/curl"

export FAKE_CURL_LOG="${TMP_DIR}/curl-calls.log"
export FAKE_CURL_STATE="${TMP_DIR}/curl-state.json"
: > "${FAKE_CURL_LOG}"

env PATH="${TMP_DIR}/curl-bin:${PATH}" \
    GITHUB_TOKEN="dummy-token" \
    JENKINS_URL="https://ci.circleguard.example" \
    WEBHOOK_SECRET="s3cr3t-super-secreto" \
    GITHUB_REPOSITORY="CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093" \
    FAKE_CURL_LOG="${FAKE_CURL_LOG}" \
    FAKE_CURL_STATE="${FAKE_CURL_STATE}" \
    "${SETUP_SCRIPT}" --force-curl > "${TMP_DIR}/curl-run-1.out" 2>&1

if ! grep -q '\-X POST' "${FAKE_CURL_LOG}"; then
    echo "ERROR: el fallback curl debía crear el webhook con POST." >&2
    cat "${FAKE_CURL_LOG}" >&2
    cat "${TMP_DIR}/curl-run-1.out" >&2
    exit 1
fi

env PATH="${TMP_DIR}/curl-bin:${PATH}" \
    GITHUB_TOKEN="dummy-token" \
    JENKINS_URL="https://ci.circleguard.example" \
    WEBHOOK_SECRET="s3cr3t-super-secreto" \
    GITHUB_REPOSITORY="CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093" \
    FAKE_CURL_LOG="${FAKE_CURL_LOG}" \
    FAKE_CURL_STATE="${FAKE_CURL_STATE}" \
    "${SETUP_SCRIPT}" --force-curl > "${TMP_DIR}/curl-run-2.out" 2>&1

if ! grep -q '\-X PATCH' "${FAKE_CURL_LOG}"; then
    echo "ERROR: el fallback curl debía actualizar el webhook con PATCH." >&2
    cat "${FAKE_CURL_LOG}" >&2
    cat "${TMP_DIR}/curl-run-2.out" >&2
    exit 1
fi
grep -q 'Webhook actualizado' "${TMP_DIR}/curl-run-2.out"

CURL_POST_COUNT="$(grep -c '\-X POST' "${FAKE_CURL_LOG}" || true)"
CURL_PATCH_COUNT="$(grep -c '\-X PATCH' "${FAKE_CURL_LOG}" || true)"
if [[ "${CURL_POST_COUNT}" -ne 1 || "${CURL_PATCH_COUNT}" -ne 1 ]]; then
    echo "ERROR: idempotencia curl incorrecta (POST=${CURL_POST_COUNT}, PATCH=${CURL_PATCH_COUNT})." >&2
    cat "${FAKE_CURL_LOG}" >&2
    exit 1
fi
echo "[OK] Fallback curl: primera ejecucion POST y segunda PATCH sin duplicar el webhook."
echo "=== VALIDACION DEL WEBHOOK DE GITHUB COMPLETADA ==="
