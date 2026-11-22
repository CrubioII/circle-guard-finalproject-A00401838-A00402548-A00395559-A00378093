#!/usr/bin/env bash
# =============================================================================
# Carga idempotente de credenciales de Jenkins y SonarQube — CircleGuard (US-04 / US-10 / US-30)
#
# Completa lo que bootstrap-ci.sh no puede hacer solo porque requiere secretos personales:
#   - github-token        (Secret text con el PAT de GitHub)
#   - github-credentials  (Username with password: usuario GitHub + PAT)
#   - circleguard-env-ssh (SSH Username with private key: ec2-user + llave de los nodos)
#   - SonarQube: cambia la contraseña por defecto admin/admin, genera un token, lo guarda en
#     Jenkins como 'sonar-token' y corre jenkins/ci/setup-sonarqube-quality-gate.sh.
# Al final dispara el escaneo del job Multibranch.
#
# Los secretos se piden por consola sin eco y nunca se escriben en disco ni en Git.
# La contraseña de admin de Jenkins se lee por SSH del .env.ci del servidor (lo genera
# bootstrap-ci.sh, US-31); también puede pasarse con JENKINS_AUTH="admin:<contraseña>".
#
# Uso:
#   bash infra/bootstrap/configure-jenkins-credentials.sh
#   bash infra/bootstrap/configure-jenkins-credentials.sh --skip-sonar
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CI_HOST="${CI_HOST:-18.117.90.15}"
JENKINS_URL="${JENKINS_URL:-http://${CI_HOST}:8080}"
SONAR_URL="${SONAR_URL:-http://${CI_HOST}:9000}"
GITHUB_USER="${GITHUB_USER:-CrubioII}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${REPO_ROOT}/proyectoIngeClave.pem}"
SSH_USER="${SSH_USER:-ec2-user}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:-/opt/circleguard-ci/infra/bootstrap/.env.ci}"
JOB_NAME="${JOB_NAME:-circleguard-monorepo}"
SKIP_SONAR="${SKIP_SONAR:-false}"
JENKINS_AUTH="${JENKINS_AUTH:-}"

log_info() { printf '[jenkins-creds][INFO]  %s\n' "$*"; }
log_ok()   { printf '[jenkins-creds][OK]    %s\n' "$*"; }
log_warn() { printf '[jenkins-creds][WARN]  %s\n' "$*" >&2; }
log_error(){ printf '[jenkins-creds][ERROR] %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Uso: infra/bootstrap/configure-jenkins-credentials.sh [opciones]
  --ci-host <ip>         IP del servidor CI (por defecto 18.117.90.15)
  --github-user <user>   Usuario de GitHub dueño del PAT (por defecto CrubioII)
  --ssh-key <ruta>       Llave privada de los nodos (por defecto ./proyectoIngeClave.pem)
  --skip-sonar           No configura SonarQube
  -h, --help             Muestra esta ayuda
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci-host)     CI_HOST="${2:?}"; JENKINS_URL="http://${CI_HOST}:8080"; SONAR_URL="http://${CI_HOST}:9000"; shift 2 ;;
        --github-user) GITHUB_USER="${2:?}"; shift 2 ;;
        --ssh-key)     SSH_KEY_PATH="${2:?}"; shift 2 ;;
        --skip-sonar)  SKIP_SONAR="true"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) log_error "Opción no reconocida: $1"; usage; exit 1 ;;
    esac
done

for bin in curl base64 ssh; do
    command -v "$bin" >/dev/null || { log_error "Falta el binario '$bin'."; exit 1; }
done
[[ -f "$SSH_KEY_PATH" ]] || { log_error "No se encontró la llave SSH en ${SSH_KEY_PATH}."; exit 1; }

curlrc_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf "%s" "$s"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
COOKIES="${WORK_DIR}/cookies"
umask 077

# Contraseña de admin de Jenkins: del entorno o del .env.ci del servidor (vía SSH).
if [[ -z "$JENKINS_AUTH" ]]; then
    admin_pass="$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${CI_HOST}" \
        "sudo grep '^JENKINS_ADMIN_PASSWORD=' '${REMOTE_ENV_FILE}' | tail -n1 | cut -d= -f2-" 2>/dev/null | tr -d '\r"' || true)"
    [[ -n "$admin_pass" ]] || { log_error "No pude leer JENKINS_ADMIN_PASSWORD de ${REMOTE_ENV_FILE}. Exporta JENKINS_AUTH=admin:<contraseña>."; exit 1; }
    JENKINS_AUTH="admin:${admin_pass}"
    unset admin_pass
fi
printf 'user = "%s"\n' "$(curlrc_escape "$JENKINS_AUTH")" > "${WORK_DIR}/jenkins.curlrc"

jcurl() { curl -fsS -K "${WORK_DIR}/jenkins.curlrc" -c "$COOKIES" -b "$COOKIES" "$@"; }

# Ejecuta un script Groovy en la consola de scripts de Jenkins (con crumb CSRF).
run_groovy() {
    local crumb_json crumb_field crumb
    crumb_json="$(jcurl "${JENKINS_URL}/crumbIssuer/api/json")"
    crumb_field="$(printf '%s' "$crumb_json" | sed -E 's/.*"crumbRequestField":"([^"]+)".*/\1/')"
    crumb="$(printf '%s' "$crumb_json" | sed -E 's/.*"crumb":"([^"]+)".*/\1/')"
    jcurl -H "${crumb_field}: ${crumb}" --data-urlencode "script@$1" "${JENKINS_URL}/scriptText"
}

# Crea o reemplaza credenciales globales. Recibe líneas "tipo|id|descripción|valor1_b64|valor2_b64".
upsert_credentials() {
    {
        cat <<'EOF'
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.plugins.credentials.impl.*
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret
def dec = { String s -> new String(s.decodeBase64(), 'UTF-8') }
def store = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()
def upsert = { c ->
    def old = store.getCredentials(domain).find { it.id == c.id }
    if (old) { store.updateCredentials(domain, old, c); println "actualizada: ${c.id}" }
    else { store.addCredentials(domain, c); println "creada: ${c.id}" }
}
EOF
        local kind id desc v1 v2
        while IFS='|' read -r kind id desc v1 v2; do
            case "$kind" in
                string) printf "upsert(new StringCredentialsImpl(CredentialsScope.GLOBAL, '%s', '%s', Secret.fromString(dec('%s'))))\n" "$id" "$desc" "$v1" ;;
                userpass) printf "upsert(new UsernamePasswordCredentialsImpl(CredentialsScope.GLOBAL, '%s', '%s', dec('%s'), dec('%s')))\n" "$id" "$desc" "$v1" "$v2" ;;
                ssh) printf "upsert(new BasicSSHUserPrivateKey(CredentialsScope.GLOBAL, '%s', dec('%s'), new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(dec('%s')), '', '%s'))\n" "$id" "$v1" "$v2" "$desc" ;;
            esac
        done
    } > "${WORK_DIR}/creds.groovy"
    run_groovy "${WORK_DIR}/creds.groovy"
}

log_info "Jenkins: ${JENKINS_URL}"
jcurl -o /dev/null "${JENKINS_URL}/api/json" || { log_error "Jenkins rechazó la autenticación o no responde."; exit 1; }
log_ok "Autenticado en Jenkins como admin."

# 1. GitHub + SSH
printf 'GitHub Personal Access Token (Enter para conservar el que ya está en Jenkins): '
read -rs GITHUB_PAT || true; echo
creds=""
if [[ -n "$GITHUB_PAT" ]]; then
    pat_login="$(curl -fsS -H "Authorization: Bearer ${GITHUB_PAT}" https://api.github.com/user | sed -nE 's/.*"login": *"([^"]+)".*/\1/p' | head -1 || true)"
    [[ -n "$pat_login" ]] || { log_error "GitHub rechazó el PAT."; exit 1; }
    log_ok "PAT válido para '${pat_login}'."
    GITHUB_USER="$pat_login"
    creds+="string|github-token|PAT de GitHub para API y Branch Source (US-30)|$(b64 "$GITHUB_PAT")|"$'\n'
    creds+="userpass|github-credentials|Usuario + PAT de GitHub para clonado y githubNotify (US-30)|$(b64 "$GITHUB_USER")|$(b64 "$GITHUB_PAT")"$'\n'
fi
creds+="ssh|circleguard-env-ssh|Llave SSH de los nodos dev/stage/prod (US-05 / US-13)|$(b64 "$SSH_USER")|$(base64 < "$SSH_KEY_PATH" | tr -d '\n')"$'\n'
printf '%s' "$creds" | upsert_credentials
unset GITHUB_PAT creds

# 2. SonarQube
if [[ "$SKIP_SONAR" != "true" ]]; then
    log_info "SonarQube: ${SONAR_URL}"
    sonar_pass=""
    if curl -fsS -u admin:admin -o /dev/null "${SONAR_URL}/api/authentication/validate" && \
       curl -fsS -u admin:admin "${SONAR_URL}/api/authentication/validate" | grep -q '"valid":true'; then
        log_warn "SonarQube todavía usa la contraseña por defecto admin/admin. Hay que cambiarla."
        printf 'Nueva contraseña para el admin de SonarQube (mínimo 12 caracteres, no se mostrará): '
        read -rs sonar_pass || true; echo
        printf 'Repite la contraseña: '
        read -rs sonar_pass2 || true; echo
        [[ "$sonar_pass" == "$sonar_pass2" ]] || { log_error "Las contraseñas no coinciden."; exit 1; }
        [[ ${#sonar_pass} -ge 12 ]] || { log_error "Mínimo 12 caracteres."; exit 1; }
        curl -fsS -u admin:admin -X POST "${SONAR_URL}/api/users/change_password" \
            --data-urlencode "login=admin" --data-urlencode "previousPassword=admin" \
            --data-urlencode "password=${sonar_pass}" >/dev/null
        unset sonar_pass2
        log_ok "Contraseña del admin de SonarQube cambiada."
    else
        printf 'Contraseña actual del admin de SonarQube (no se mostrará): '
        read -rs sonar_pass || true; echo
    fi
    printf 'user = "admin:%s"\n' "$(curlrc_escape "$sonar_pass")" > "${WORK_DIR}/sonar.curlrc"
    unset sonar_pass

    token_name="jenkins-$(date +%Y%m%d%H%M%S)"
    sonar_token="$(curl -fsS -K "${WORK_DIR}/sonar.curlrc" -X POST "${SONAR_URL}/api/user_tokens/generate" \
        --data-urlencode "name=${token_name}" | sed -nE 's/.*"token":"([^"]+)".*/\1/p')"
    [[ -n "$sonar_token" ]] || { log_error "SonarQube no generó el token (¿contraseña incorrecta?)."; exit 1; }
    log_ok "Token de SonarQube '${token_name}' generado."

    printf 'string|sonar-token|Token de SonarQube para análisis y Quality Gate (US-10)|%s|\n' "$(b64 "$sonar_token")" | upsert_credentials

    log_info "Configurando proyecto, Quality Gate y webhook en SonarQube..."
    SONAR_TOKEN="$sonar_token" SONAR_HOST_URL="$SONAR_URL" JENKINS_URL="$JENKINS_URL" \
        bash "${REPO_ROOT}/jenkins/ci/setup-sonarqube-quality-gate.sh"
    unset sonar_token
fi

# 3. Escaneo del job Multibranch con las credenciales nuevas.
cat > "${WORK_DIR}/scan.groovy" <<EOF
def job = jenkins.model.Jenkins.get().getItemByFullName('${JOB_NAME}')
if (job == null) { println "No existe el job ${JOB_NAME}"; return }
job.scheduleBuild2(0)
println "Escaneo de ${JOB_NAME} programado."
EOF
run_groovy "${WORK_DIR}/scan.groovy"

log_ok "Listo. Las contraseñas de las cuentas de Jenkins están en ${REMOTE_ENV_FILE} del servidor CI."
