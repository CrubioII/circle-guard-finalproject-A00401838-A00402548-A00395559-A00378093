#!/usr/bin/env bash
# =============================================================================
# CircleGuard Web Client - Container Verification Suite (US-07 / SCRUM-51)
#
# Verifies:
#   1. Multi-stage Docker build succeeds (CA1)
#   2. Non-root runtime user (UID 101 != 0) and EXPOSE 8080 + HEALTHCHECK (CA2)
#   3. Container boots and reaches Docker "healthy" state via /healthz (CA2)
#   4. SPA routing serves index/route HTML for /, /login, /questionnaire, and arbitrary SPA paths (CA2)
#   5. Dynamic backend/gateway URL injection via /runtime-config.js across dev/stage/prod (CA3)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="${IMAGE_NAME:-circleguard/web-client:1.0.0-SNAPSHOT}"
CONTAINER_NAME="circleguard-web-verify-$$"
HOST_PORT="${HOST_PORT:-18080}"

cleanup() {
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> [1/5] Building ${IMAGE_NAME} from mobile/Dockerfile..."
DOCKER_BUILDKIT=1 docker build -f "${MOBILE_DIR}/Dockerfile" -t "${IMAGE_NAME}" "${MOBILE_DIR}"

echo "==> [2/5] Inspecting image security and metadata (CA1, CA2)..."
IMAGE_USER="$(docker inspect --format '{{.Config.User}}' "${IMAGE_NAME}")"
EXPOSED_PORTS="$(docker inspect --format '{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' "${IMAGE_NAME}")"
HEALTHCHECK_CMD="$(docker inspect --format '{{json .Config.Healthcheck.Test}}' "${IMAGE_NAME}")"
RUNTIME_UID="$(docker run --rm --entrypoint id "${IMAGE_NAME}" -u)"
RUNTIME_WHOAMI="$(docker run --rm --entrypoint whoami "${IMAGE_NAME}")"

echo "    Configured USER : ${IMAGE_USER}"
echo "    Runtime UID     : ${RUNTIME_UID} (${RUNTIME_WHOAMI})"
echo "    Exposed ports   : ${EXPOSED_PORTS}"
echo "    Healthcheck     : ${HEALTHCHECK_CMD}"

if [[ "${RUNTIME_UID}" == "0" || "${RUNTIME_WHOAMI}" == "root" ]]; then
    echo "FAIL: Container runs as root (${RUNTIME_WHOAMI} / UID ${RUNTIME_UID})" >&2
    exit 1
fi
if [[ "${EXPOSED_PORTS}" != *"8080/tcp"* ]]; then
    echo "FAIL: Expected 8080/tcp in ExposedPorts, got: ${EXPOSED_PORTS}" >&2
    exit 1
fi
if [[ "${HEALTHCHECK_CMD}" != *"/healthz"* ]]; then
    echo "FAIL: Expected /healthz in HEALTHCHECK, got: ${HEALTHCHECK_CMD}" >&2
    exit 1
fi

echo "==> [3/5] Starting container with dynamic 'stage' environment URLs (CA2, CA3)..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${HOST_PORT}:8080" \
    -e APP_ENV="stage" \
    -e API_BASE_URL="http://172.31.19.153:8087" \
    -e GATEWAY_BASE_URL="http://172.31.19.153:8087" \
    -e AUTH_BASE_URL="http://172.31.19.153:8180" \
    -e IDENTITY_BASE_URL="http://172.31.19.153:8083" \
    -e PROMOTION_BASE_URL="http://172.31.19.153:8088" \
    -e FORM_BASE_URL="http://172.31.19.153:8086" \
    "${IMAGE_NAME}" >/dev/null

echo "==> Waiting for container healthcheck to report 'healthy'..."
for _ in $(seq 1 30); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "starting")"
    if [[ "${status}" == "healthy" ]]; then
        break
    fi
    sleep 1
done

FINAL_HEALTH="$(docker inspect --format '{{.State.Health.Status}}' "${CONTAINER_NAME}")"
if [[ "${FINAL_HEALTH}" != "healthy" ]]; then
    echo "FAIL: Container did not become healthy (status=${FINAL_HEALTH})" >&2
    docker logs "${CONTAINER_NAME}" >&2
    exit 1
fi
echo "    Container health status: ${FINAL_HEALTH}"

echo "==> [4/5] Verifying /healthz and SPA route navigation (CA2)..."
HEALTH_BODY="$(curl -fsS "http://127.0.0.1:${HOST_PORT}/healthz")"
if [[ "${HEALTH_BODY}" != *'"status":"UP"'* ]]; then
    echo "FAIL: Unexpected /healthz payload: ${HEALTH_BODY}" >&2
    exit 1
fi

for route in "/" "/login" "/questionnaire" "/visitor" "/spa/deep-link/check"; do
    http_code="$(curl -s -o /tmp/cg_route_check.html -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}${route}")"
    if [[ "${http_code}" != "200" ]]; then
        echo "FAIL: Route ${route} returned HTTP ${http_code}" >&2
        exit 1
    fi
    if ! grep -q '/runtime-config.js' /tmp/cg_route_check.html; then
        echo "FAIL: Route ${route} HTML does not include /runtime-config.js script tag" >&2
        exit 1
    fi
    echo "    SPA route ${route} -> HTTP ${http_code} OK"
done
rm -f /tmp/cg_route_check.html

echo "==> [5/5] Verifying dynamic backend/gateway URL config in /runtime-config.js (CA3)..."
RUNTIME_JS="$(curl -fsS "http://127.0.0.1:${HOST_PORT}/runtime-config.js")"
echo "${RUNTIME_JS}"

for expected in \
    'APP_ENV: "stage"' \
    'GATEWAY_BASE_URL: "http://172.31.19.153:8087"' \
    'AUTH_BASE_URL: "http://172.31.19.153:8180"' \
    'FORM_BASE_URL: "http://172.31.19.153:8086"'; do
    if [[ "${RUNTIME_JS}" != *"${expected}"* ]]; then
        echo "FAIL: /runtime-config.js missing expected entry: ${expected}" >&2
        exit 1
    fi
done

echo "==> All US-07 checks passed (CA1, CA2, CA3)."
