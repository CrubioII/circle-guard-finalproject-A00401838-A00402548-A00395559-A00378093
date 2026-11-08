#!/usr/bin/env bash
# =============================================================================
# jenkins/ci/setup-github-webhook.sh
# Historia de Usuario: US-30 (SCRUM-113 / SCRUM-57)
#
# Registra (o actualiza de forma idempotente) el webhook de GitHub que dispara
# el job Multibranch 'circleguard-monorepo' en Jenkins.
#
# Uso:
#   export GITHUB_TOKEN="ghp_..."           # scope repo + admin:repo_hook
#   export JENKINS_URL="https://ci.ejemplo.com"   # o https://xxx.ngrok-free.app
#   ./jenkins/ci/setup-github-webhook.sh
#
# Opciones:
#   --dry-run                 Muestra el payload y el destino sin llamar a GitHub.
#   --force-curl              Usa curl aunque el binario gh esté instalado.
#   --jenkins-url <url>       URL base de Jenkins (alternativa a JENKINS_URL).
#   --repo <owner/repo>       Repositorio destino (por defecto GITHUB_REPOSITORY
#                             o CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093).
#   -h | --help               Muestra esta ayuda.
#
# Variables de entorno:
#   GITHUB_TOKEN      Token con permisos sobre el repositorio (obligatorio salvo --dry-run).
#   WEBHOOK_SECRET    Secreto compartido recomendado (Jenkins lo valida si se configura).
# =============================================================================

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093}"
JENKINS_URL="${JENKINS_URL:-}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
DRY_RUN=false
FORCE_CURL=false

usage() {
    cat <<'EOF'
Registra el webhook de GitHub para el Multibranch Pipeline de CircleGuard.

Uso:
  GITHUB_TOKEN=... JENKINS_URL=https://jenkins.ejemplo.com ./jenkins/ci/setup-github-webhook.sh [opciones]

Opciones:
  --dry-run              Muestra el payload (secreto enmascarado) sin modificar GitHub.
  --force-curl           Usa curl aunque gh esté instalado (útil en pruebas/CI).
  --jenkins-url <url>    URL base de Jenkins (por defecto variable JENKINS_URL).
  --repo <owner/repo>    Repositorio destino (por defecto GITHUB_REPOSITORY).
  -h, --help             Muestra esta ayuda.

Notas:
  - La URL registrada es <jenkins-url>/github-webhook/ (endpoint del plugin GitHub).
  - Eventos suscritos: push, pull_request, create, delete.
  - Requiere el binario `gh` (recomendado) o `curl`, y `python3` para construir el JSON.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --force-curl)
            FORCE_CURL=true
            shift
            ;;
        --jenkins-url)
            JENKINS_URL="${2:-}"
            shift 2
            ;;
        --repo)
            REPO="${2:-}"
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
    echo "ERROR: se requiere python3 para construir y validar el payload JSON." >&2
    exit 1
fi

if [[ ! "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: repositorio inválido '${REPO}'. Formato esperado: owner/repo." >&2
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

JENKINS_BASE="${JENKINS_URL%/}"
if [[ "${JENKINS_BASE}" == */github-webhook ]]; then
    WEBHOOK_URL="${JENKINS_BASE}/"
else
    WEBHOOK_URL="${JENKINS_BASE}/github-webhook/"
fi

PAYLOAD="$(WEBHOOK_URL="${WEBHOOK_URL}" WEBHOOK_SECRET="${WEBHOOK_SECRET}" python3 -c '
import json
import os

config = {
    "url": os.environ["WEBHOOK_URL"],
    "content_type": "json",
    "insecure_ssl": "0",
}
secret = os.environ.get("WEBHOOK_SECRET", "")
if secret:
    config["secret"] = secret
print(json.dumps({
    "name": "web",
    "active": True,
    "events": ["push", "pull_request", "create", "delete"],
    "config": config,
}))
')"

if [[ "${DRY_RUN}" == "true" ]]; then
    MASKED_PAYLOAD="$(PAYLOAD="${PAYLOAD}" python3 -c '
import json
import os

data = json.loads(os.environ["PAYLOAD"])
if data.get("config", {}).get("secret"):
    data["config"]["secret"] = "***"
print(json.dumps(data, indent=2, ensure_ascii=False))
')"
    cat <<EOF
[DRY-RUN] No se modificó GitHub.
Repositorio : ${REPO}
Webhook URL : ${WEBHOOK_URL}
Eventos     : push, pull_request, create, delete
Método      : POST (crear) si no existe / PATCH (actualizar) si ya existe
Payload     :
${MASKED_PAYLOAD}
EOF
    exit 0
fi

if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "ERROR: exporta GITHUB_TOKEN con scope repo + admin:repo_hook para registrar el webhook." >&2
    exit 1
fi

extract_hook_id() {
    HOOKS_JSON="${1}" WEBHOOK_URL="${WEBHOOK_URL}" python3 -c '
import json
import os

try:
    hooks = json.loads(os.environ.get("HOOKS_JSON", "[]"))
except Exception:
    hooks = []
target = os.environ.get("WEBHOOK_URL", "")
for hook in hooks:
    if isinstance(hook, dict) and hook.get("config", {}).get("url") == target:
        print(hook.get("id", ""))
        break
'
}

extract_response_id() {
    RESPONSE_JSON="${1}" python3 -c '
import json
import os

try:
    data = json.loads(os.environ.get("RESPONSE_JSON", "{}"))
except Exception:
    data = {}
print(data.get("id", ""))
'
}

ACTION=""
RESPONSE=""
HOOK_ID=""

if [[ "${FORCE_CURL}" != "true" ]] && command -v gh >/dev/null 2>&1; then
    HOOKS_JSON="$(gh api --paginate "repos/${REPO}/hooks")"
    HOOK_ID="$(extract_hook_id "${HOOKS_JSON}")"

    if [[ -n "${HOOK_ID}" ]]; then
        RESPONSE="$(printf '%s' "${PAYLOAD}" | gh api --method PATCH "repos/${REPO}/hooks/${HOOK_ID}" --input -)"
        ACTION="actualizado"
    else
        RESPONSE="$(printf '%s' "${PAYLOAD}" | gh api --method POST "repos/${REPO}/hooks" --input -)"
        ACTION="creado"
    fi
else
    API_HOOKS_URL="https://api.github.com/repos/${REPO}/hooks"
    API_LIST_URL="${API_HOOKS_URL}?per_page=100"
    AUTH_HEADERS=(
        -H "Authorization: Bearer ${GITHUB_TOKEN}"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )

    HOOKS_JSON="$(curl -fsSL "${AUTH_HEADERS[@]}" "${API_LIST_URL}")"
    HOOK_ID="$(extract_hook_id "${HOOKS_JSON}")"

    if [[ -n "${HOOK_ID}" ]]; then
        RESPONSE="$(printf '%s' "${PAYLOAD}" | curl -fsSL -X PATCH "${AUTH_HEADERS[@]}" \
            -H "Content-Type: application/json" --data @- "${API_HOOKS_URL}/${HOOK_ID}")"
        ACTION="actualizado"
    else
        RESPONSE="$(printf '%s' "${PAYLOAD}" | curl -fsSL -X POST "${AUTH_HEADERS[@]}" \
            -H "Content-Type: application/json" --data @- "${API_HOOKS_URL}")"
        ACTION="creado"
    fi
fi

RESPONSE_ID="$(extract_response_id "${RESPONSE}")"
FINAL_ID="${RESPONSE_ID:-${HOOK_ID}}"

echo "[OK] Webhook ${ACTION} en ${REPO} (id=${FINAL_ID:-desconocido})."
echo "     URL     : ${WEBHOOK_URL}"
echo "     Eventos : push, pull_request, create, delete"
if [[ -n "${WEBHOOK_SECRET}" ]]; then
    echo "     Secreto : configurado (no se imprime)."
else
    echo "     Secreto : no configurado (define WEBHOOK_SECRET y vuelve a ejecutar)."
fi
echo "     Verifica en: https://github.com/${REPO}/settings/hooks"
