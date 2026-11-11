#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Entrypoint de Jenkins (US-31)
#
# Antes de arrancar Jenkins comprueba que existan y no estén vacíos los secretos de las
# cuentas declaradas en jenkins/ci/jenkins.yaml (CG_REQUIRED_SECRETS). JCasC resuelve
# ${NOMBRE} leyendo /run/secrets/NOMBRE; si el archivo faltara, la cuenta quedaría con una
# contraseña vacía o literal. Por eso es preferible no arrancar.
#
# Nunca imprime el contenido de los secretos, solo sus nombres.
# =============================================================================
set -euo pipefail

SECRETS_DIR="${SECRETS:-/run/secrets}"
missing=()
for name in ${CG_REQUIRED_SECRETS:-}; do
    if [[ ! -s "${SECRETS_DIR}/${name}" ]] || ! grep -q '[^[:space:]]' "${SECRETS_DIR}/${name}"; then
        missing+=("${name}")
    fi
done

if (( ${#missing[@]} > 0 )); then
    {
        echo "[cg-entrypoint][ERROR] Faltan secretos de Jenkins (US-31): ${missing[*]}"
        echo "[cg-entrypoint][ERROR] Defínelos en infra/bootstrap/.env.ci (bootstrap-ci.sh los genera) y vuelve a ejecutar:"
        echo "[cg-entrypoint][ERROR]   docker compose -f docker-compose.ci.yml --env-file infra/bootstrap/.env.ci up -d"
    } >&2
    exit 64
fi

exec /usr/bin/tini -- /usr/local/bin/jenkins.sh "$@"
