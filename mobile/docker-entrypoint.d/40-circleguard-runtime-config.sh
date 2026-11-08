#!/bin/sh
# =============================================================================
# CircleGuard Web Client - Runtime Environment Configuration Generator (US-07)
# Executed automatically by /docker-entrypoint.sh as non-root user (UID 101).
# Writes /tmp/circleguard-runtime-config.js so a single immutable image can
# dynamically point to dev, stage, or prod backend endpoints at container start.
# =============================================================================
set -eu

OUTPUT_FILE="/tmp/circleguard-runtime-config.js"

APP_ENV_VAL="${APP_ENV:-${EXPO_PUBLIC_APP_ENV:-dev}}"
AUTH_URL_VAL="${AUTH_BASE_URL:-${EXPO_PUBLIC_AUTH_BASE_URL:-http://localhost:8180}}"
IDENTITY_URL_VAL="${IDENTITY_BASE_URL:-${EXPO_PUBLIC_IDENTITY_BASE_URL:-http://localhost:8083}}"
PROMOTION_URL_VAL="${PROMOTION_BASE_URL:-${EXPO_PUBLIC_PROMOTION_BASE_URL:-http://localhost:8088}}"
FORM_URL_VAL="${FORM_BASE_URL:-${EXPO_PUBLIC_FORM_BASE_URL:-http://localhost:8086}}"
GATEWAY_URL_VAL="${GATEWAY_BASE_URL:-${EXPO_PUBLIC_GATEWAY_BASE_URL:-${API_BASE_URL:-${EXPO_PUBLIC_API_BASE_URL:-http://localhost:8087}}}}"
API_URL_VAL="${API_BASE_URL:-${EXPO_PUBLIC_API_BASE_URL:-${GATEWAY_URL_VAL}}}"
FILE_URL_VAL="${FILE_BASE_URL:-${EXPO_PUBLIC_FILE_BASE_URL:-http://localhost:8085}}"
NOTIFICATION_URL_VAL="${NOTIFICATION_BASE_URL:-${EXPO_PUBLIC_NOTIFICATION_BASE_URL:-http://localhost:8082}}"
DASHBOARD_URL_VAL="${DASHBOARD_BASE_URL:-${EXPO_PUBLIC_DASHBOARD_BASE_URL:-http://localhost:8084}}"

escape_js() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

cat > "${OUTPUT_FILE}" <<EOF
window.__CIRCLEGUARD_CONFIG__ = Object.freeze({
  APP_ENV: "$(escape_js "${APP_ENV_VAL}")",
  API_BASE_URL: "$(escape_js "${API_URL_VAL}")",
  GATEWAY_BASE_URL: "$(escape_js "${GATEWAY_URL_VAL}")",
  AUTH_BASE_URL: "$(escape_js "${AUTH_URL_VAL}")",
  IDENTITY_BASE_URL: "$(escape_js "${IDENTITY_URL_VAL}")",
  PROMOTION_BASE_URL: "$(escape_js "${PROMOTION_URL_VAL}")",
  FORM_BASE_URL: "$(escape_js "${FORM_URL_VAL}")",
  FILE_BASE_URL: "$(escape_js "${FILE_URL_VAL}")",
  NOTIFICATION_BASE_URL: "$(escape_js "${NOTIFICATION_URL_VAL}")",
  DASHBOARD_BASE_URL: "$(escape_js "${DASHBOARD_URL_VAL}")"
});
EOF

chmod 0644 "${OUTPUT_FILE}"
echo "[circleguard-web] Runtime config generated at ${OUTPUT_FILE} for APP_ENV=${APP_ENV_VAL} (GATEWAY_BASE_URL=${GATEWAY_URL_VAL})"
