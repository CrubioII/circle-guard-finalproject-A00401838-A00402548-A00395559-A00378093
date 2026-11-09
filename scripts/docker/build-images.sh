#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Build the 8 backend images (US-06)
#
# Usage:
#   scripts/docker/build-images.sh [service-short-name ...]
#   TAG=1.2.3 REGISTRY=myregistry/circleguard scripts/docker/build-images.sh auth-service
#
# Without arguments it builds all 8 services. 'web-client' (mobile/, US-07) can be requested
# explicitly, e.g. to build the 6 images of deploy/compose (US-08):
#   TAG=1.2.0 REGISTRY=52.14.6.11:5000/circleguard scripts/docker/build-images.sh #     auth-service identity-service promotion-service form-service gateway-service web-client
# Images are tagged
#   ${REGISTRY}/<service>:${TAG}       (default: circleguard/<service>:1.0.0-SNAPSHOT)
# The ':latest' tag is never produced on purpose (immutable versioned images).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY="${REGISTRY:-circleguard}"
TAG="${TAG:-1.0.0-SNAPSHOT}"

ALL_SERVICES=(
  auth-service identity-service promotion-service form-service gateway-service
  notification-service file-service dashboard-service
)
SERVICES=("${@:-${ALL_SERVICES[@]}}")

export DOCKER_BUILDKIT=1
cd "${ROOT_DIR}"

for svc in "${SERVICES[@]}"; do
  if [[ "${svc}" == "web-client" ]]; then
    dockerfile="mobile/Dockerfile"
    context="mobile"
  else
    dockerfile="services/circleguard-${svc}/Dockerfile"
    context="."
  fi
  if [[ ! -f "${dockerfile}" ]]; then
    echo "ERROR: ${dockerfile} not found" >&2
    exit 1
  fi
  image="${REGISTRY}/${svc}:${TAG}"
  echo "==> Building ${image}"
  docker build --file "${dockerfile}" --tag "${image}" "${context}"
done

echo
docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E "^${REGISTRY}/" || true
