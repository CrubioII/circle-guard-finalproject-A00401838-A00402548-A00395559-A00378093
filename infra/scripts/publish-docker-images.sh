#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Construcción y publicación de imágenes en Nexus (US-11 / SCRUM-23)
#
# Construye las imágenes Docker para los 8 microservicios y el cliente web,
# las etiqueta con la versión semántica calculada (US-12) y las publica en el
# registro privado Nexus:
#   <REGISTRY_URL>/circleguard/<servicio>:<semver>
#   (ej. 18.117.90.15:5000/circleguard/auth:0.1.0)
#
# Reglas obligatorias:
#   - NUNCA usar la etiqueta 'latest'.
#   - Autenticación segura mediante credenciales (withCredentials en Jenkins).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REGISTRY_URL="${REGISTRY_URL:-18.117.90.15:5000}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-circleguard}"
REGISTRY_USER="${REGISTRY_USER:-${NEXUS_USER:-}}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-${NEXUS_PASSWORD:-}}"
VERSION="${VERSION:-${APP_VERSION:-}}"
DO_PUSH="${DO_PUSH:-true}"
SKIP_LOGIN="${SKIP_LOGIN:-false}"

# Si la versión no fue especificada, se calcula dinámicamente con US-12
if [[ -z "${VERSION}" ]]; then
  VERSION="$("${SCRIPT_DIR}/calculate-semver.sh" --format version)"
fi

# Validación estricta: prohibir el tag latest
if [[ "${VERSION}" == "latest" || "${VERSION}" == *"latest"* ]]; then
  echo "ERROR: El uso del tag 'latest' está estrictamente prohibido por la política de inmutabilidad (US-11)." >&2
  exit 1
fi

echo "Iniciando publicación en Nexus con versión semántica: ${VERSION}"
echo "Registro de destino: ${REGISTRY_URL}/${REGISTRY_NAMESPACE}"

# Iniciar sesión en el registro Docker si se proporcionan credenciales
if [[ "${SKIP_LOGIN}" != "true" && -n "${REGISTRY_USER}" && -n "${REGISTRY_PASSWORD}" ]]; then
  echo "Autenticando contra el registro ${REGISTRY_URL}..."
  echo "${REGISTRY_PASSWORD}" | docker login -u "${REGISTRY_USER}" --password-stdin "${REGISTRY_URL}"
  echo "Autenticación exitosa en ${REGISTRY_URL}."
fi

cd "${ROOT_DIR}"
export DOCKER_BUILDKIT=1

# Lista de microservicios backend y cliente web
BACKEND_SERVICES=(auth identity promotion notification form file gateway dashboard)

for svc in "${BACKEND_SERVICES[@]}"; do
  dockerfile="services/circleguard-${svc}-service/Dockerfile"
  if [[ ! -f "${dockerfile}" ]]; then
    echo "ERROR: No se encontró el Dockerfile para ${svc} en ${dockerfile}" >&2
    exit 1
  fi

  target_image="${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${svc}:${VERSION}"
  alias_image="${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${svc}-service:${VERSION}"

  echo "==> Construyendo ${target_image}..."
  docker build -f "${dockerfile}" -t "${target_image}" -t "${alias_image}" .

  if [[ "${DO_PUSH}" == "true" ]]; then
    echo "==> Publicando ${target_image}..."
    docker push "${target_image}"
    docker push "${alias_image}"
  fi
done

# Construir y publicar cliente web (mobile)
web_dockerfile="mobile/Dockerfile"
if [[ -f "${web_dockerfile}" ]]; then
  web_target="${REGISTRY_URL}/${REGISTRY_NAMESPACE}/mobile:${VERSION}"
  # Nombre que consumen deploy/compose/docker-compose.<env>.yml (US-08) y el despliegue de US-13.
  web_compose_target="${REGISTRY_URL}/${REGISTRY_NAMESPACE}/web-client:${VERSION}"
  echo "==> Construyendo cliente web ${web_target}..."
  docker build -f "${web_dockerfile}" -t "${web_target}" -t "${web_compose_target}" mobile/

  if [[ "${DO_PUSH}" == "true" ]]; then
    echo "==> Publicando cliente web ${web_target}..."
    docker push "${web_target}"
    docker push "${web_compose_target}"
  fi
else
  echo "ADVERTENCIA: No se encontró ${web_dockerfile}, omitiendo cliente web." >&2
fi

echo "Todas las imágenes han sido construidas y etiquetadas con la versión ${VERSION}."
