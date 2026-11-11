#!/usr/bin/env bash
# =============================================================================
# jenkins/test/validateJenkinsSecurity.sh
# Historia de Usuario: US-31 — Seguridad de Jenkins y aprobadores de prod
#
# Valida, sin Jenkins ni Docker, que la configuración de seguridad versionada sea coherente:
#   1. jenkins/ci/jenkins.yaml declara cuentas locales sin registro público y contraseñas
#      solo por referencia ${...} (nunca en texto plano).
#   2. La matriz de permisos: solo 'admin' administra, el usuario anónimo no tiene permisos,
#      'docente' solo lee y nadie más tiene permisos que permitan ejecutar código propio.
#   3. Los aprobadores de prod (CG_PROD_APPROVERS) existen como cuentas y no son admin ni docente.
#   4. La misma lista de secretos en jenkins.yaml, docker-compose.ci.yml (secrets y
#      CG_REQUIRED_SECRETS), bootstrap-ci.sh y .env.ci.example.
#
# Uso: bash jenkins/test/validateJenkinsSecurity.sh   (o ./gradlew validateJenkinsSecurity)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JCASC="${JCASC_FILE:-${REPO_ROOT}/jenkins/ci/jenkins.yaml}"
COMPOSE="${COMPOSE_FILE:-${REPO_ROOT}/docker-compose.ci.yml}"
BOOTSTRAP="${REPO_ROOT}/infra/bootstrap/bootstrap-ci.sh"
TEMPLATE="${REPO_ROOT}/infra/bootstrap/.env.ci.example"
PLUGINS="${REPO_ROOT}/infra/bootstrap/jenkins/plugins.txt"
ENTRYPOINT="${REPO_ROOT}/infra/bootstrap/jenkins/cg-entrypoint.sh"

PASS=0
FAIL=0
ok()   { printf '  [OK]   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }

# Normaliza fin de línea (los archivos pueden venir con CRLF en Windows).
strip() { tr -d '\r' < "$1"; }
sorted_words() { tr ' ,' '\n\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

printf '=== Seguridad de Jenkins (US-31) ===\n'

# --- 1. Cuentas locales -------------------------------------------------------
REALM="$(strip "$JCASC" | awk '/^  securityRealm:/{f=1;next} f&&/^  [a-zA-Z]/{f=0} f')"
check "jenkins.yaml declara securityRealm local" grep -q '^    local:' <<< "$REALM"
check "El registro público de cuentas está desactivado (allowsSignup: false)" grep -q 'allowsSignup: false' <<< "$REALM"
USERS="$(grep -E '^ *- id: ' <<< "$REALM" | sed -E 's/.*id: *"?([^"]+)"?.*/\1/' | sorted_words)"
check "Existen las cuentas admin, docente y las del equipo (${USERS})" test "$USERS" == "admin docente ecuellar jpordonez jrubio scastillo"
PWD_LINES="$(grep -E '^ *password:' <<< "$REALM" || true)"
PWD_COUNT="$(grep -c . <<< "$PWD_LINES" || true)"
USER_COUNT="$(wc -w <<< "$USERS")"
check "Cada cuenta tiene contraseña (${PWD_COUNT}/${USER_COUNT})" test "$PWD_COUNT" -eq "$USER_COUNT"
check "Ninguna contraseña está en texto plano (solo referencias \${JENKINS_...})" \
    bash -c '! grep -Ev "password: \"\\$\\{JENKINS_[A-Z_]+\\}\"$" <<< "$1" | grep -q .' _ "$PWD_LINES"
YAML_SECRETS="$(sed -E 's/.*\$\{([A-Z_]+)\}.*/\1/' <<< "$PWD_LINES" | sorted_words)"
check "No hay estrategias inseguras (loggedInUsersCanDoAnything, unsecured, allowAnonymousRead)" \
    bash -c '! tr -d "\r" < "$1" | grep -Eq "^[^#]*(loggedInUsersCanDoAnything|unsecured|allowAnonymousRead)"' _ "$JCASC"

# --- 2. Matriz de permisos ----------------------------------------------------
# Produce líneas "tipo nombre permiso" a partir de authorizationStrategy.globalMatrix.entries.
MATRIX="$(strip "$JCASC" | awk '
    /^  authorizationStrategy:/ { f = 1; next }
    f && /^  [a-zA-Z]/ { f = 0 }
    !f { next }
    /^        - (user|group):/ { type = $2; sub(":", "", type); next }
    /^            name:/ { name = $2; gsub("\"", "", name); next }
    /^              - "/ { perm = $0; sub(/^ *- "/, "", perm); sub(/".*/, "", perm); print type, name, perm }
')"
check "jenkins.yaml usa globalMatrix (matrix-auth)" bash -c 'tr -d "\r" < "$1" | grep -q "^    globalMatrix:"' _ "$JCASC"
check "matrix-auth está en plugins.txt" bash -c 'tr -d "\r" < "$1" | grep -qx "matrix-auth"' _ "$PLUGINS"
ADMINS="$(awk '$3 == "Overall/Administer" { print $1 ":" $2 }' <<< "$MATRIX" | sorted_words)"
check "Solo user:admin tiene Overall/Administer (${ADMINS:-nadie})" test "$ADMINS" == "user:admin"
check "El usuario anónimo no tiene ningún permiso" bash -c '! awk "\$2 == \"anonymous\"" <<< "$1" | grep -q .' _ "$MATRIX"
check "El grupo authenticated solo tiene Overall/Read, Job/Read y View/Read" \
    test "$(awk '$1 == "group" && $2 == "authenticated" { print $3 }' <<< "$MATRIX" | sorted_words)" == "Job/Read Overall/Read View/Read"
check "La cuenta docente no tiene permisos propios (solo lectura por authenticated)" \
    bash -c '! awk "\$2 == \"docente\"" <<< "$1" | grep -q .' _ "$MATRIX"
DANGEROUS="$(awk '$2 != "admin" && $3 ~ /^(Run\/Replay|Job\/Configure|Job\/Create|Job\/Delete|Overall\/RunScripts|Overall\/Manage|Overall\/SystemRead|Credentials\/|Agent\/|SCM\/Tag)/ { print $2 ":" $3 }' <<< "$MATRIX" | sorted_words)"
check "Ninguna cuenta distinta de admin puede ejecutar código propio ni ver credenciales (${DANGEROUS:-ninguna})" test -z "$DANGEROUS"
for member in jrubio ecuellar scastillo jpordonez; do
    check "${member} puede lanzar y cancelar builds (Job/Build y Job/Cancel)" \
        test "$(awk -v u="$member" '$1 == "user" && $2 == u && ($3 == "Job/Build" || $3 == "Job/Cancel") { print $3 }' <<< "$MATRIX" | sorted_words)" == "Job/Build Job/Cancel"
done

# --- 3. Aprobadores de prod ---------------------------------------------------
APPROVERS="$(strip "$TEMPLATE" | sed -n 's/^CG_PROD_APPROVERS=//p' | sorted_words)"
check "La plantilla define al menos 2 aprobadores de prod (${APPROVERS:-ninguno})" test "$(wc -w <<< "$APPROVERS")" -ge 2
for approver in $APPROVERS; do
    check "El aprobador '${approver}' existe como cuenta de Jenkins" grep -qw "$approver" <<< "$USERS"
    check "El aprobador '${approver}' no es admin ni docente" bash -c '[[ "$1" != admin && "$1" != docente ]]' _ "$approver"
done
check "jenkins.yaml publica CG_PROD_APPROVERS como variable global desde el entorno" \
    bash -c 'tr -d "\r" < "$1" | grep -q "value: \"\${CG_PROD_APPROVERS:-}\""' _ "$JCASC"
check "docker-compose.ci.yml pasa CG_PROD_APPROVERS al contenedor" \
    bash -c 'tr -d "\r" < "$1" | grep -q "CG_PROD_APPROVERS: \"\${CG_PROD_APPROVERS:-}\""' _ "$COMPOSE"

# --- 4. La misma lista de secretos en todos los archivos ----------------------
COMPOSE_SECRETS="$(strip "$COMPOSE" | sed -n 's/^    environment: \(JENKINS_[A-Z_]*\)$/\1/p' | sorted_words)"
REQUIRED="$(strip "$COMPOSE" | sed -n 's/^ *CG_REQUIRED_SECRETS: "\(.*\)"$/\1/p' | sorted_words)"
SERVICE_SECRETS="$(strip "$COMPOSE" | awk '/^    secrets:/{f=1;next} f&&!/^      - /{f=0} f{print $2}' | sorted_words)"
BOOT_SECRETS="$(strip "$BOOTSTRAP" | awk '/^JENKINS_SECRET_KEYS=\(/{f=1;next} f&&/^\)/{f=0} f{print $1}' | sorted_words)"
TEMPLATE_SECRETS="$(strip "$TEMPLATE" | grep -Eo '^JENKINS_(ADMIN_PASSWORD|PWD_[A-Z]+)=' | tr -d '=' | sorted_words)"
check "Secretos de docker-compose.ci.yml = contraseñas de jenkins.yaml" test "$COMPOSE_SECRETS" == "$YAML_SECRETS"
check "Secretos montados en el servicio jenkins = contraseñas de jenkins.yaml" test "$SERVICE_SECRETS" == "$YAML_SECRETS"
check "CG_REQUIRED_SECRETS (entrypoint) = contraseñas de jenkins.yaml" test "$REQUIRED" == "$YAML_SECRETS"
check "JENKINS_SECRET_KEYS de bootstrap-ci.sh = contraseñas de jenkins.yaml" test "$BOOT_SECRETS" == "$YAML_SECRETS"
check ".env.ci.example declara las mismas contraseñas, vacías" test "$TEMPLATE_SECRETS" == "$YAML_SECRETS"
check ".env.ci.example no trae ninguna contraseña con valor" \
    bash -c '! tr -d "\r" < "$1" | grep -Eq "^JENKINS_(ADMIN_PASSWORD|PWD_[A-Z]+)=.+"' _ "$TEMPLATE"
check "Las contraseñas no se pasan como variables de entorno del contenedor" \
    bash -c '! tr -d "\r" < "$1" | grep -Eq "^      JENKINS_(ADMIN_PASSWORD|PWD_[A-Z]+):"' _ "$COMPOSE"
check "El entrypoint existe y valida los secretos antes de arrancar Jenkins" \
    bash -c 'grep -q "CG_REQUIRED_SECRETS" "$1" && grep -q "exec /usr/bin/tini -- /usr/local/bin/jenkins.sh" "$1"' _ "$ENTRYPOINT"

printf '=== Seguridad de Jenkins: %d verificaciones OK, %d fallidas ===\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
