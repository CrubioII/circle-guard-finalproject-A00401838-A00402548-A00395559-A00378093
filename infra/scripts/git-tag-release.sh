#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Etiquetado y publicación de releases en Git (US-12 / SCRUM-24)
#
# Crea un tag anotado 'vX.Y.Z' en Git para la versión calculada.
# Incluye '[skip ci]' en el mensaje del tag para evitar bucles infinitos en webhooks.
# =============================================================================
set -euo pipefail

VERSION="${1:-}"
DO_PUSH="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)
      DO_PUSH="true"
      shift
      ;;
    -v|--version)
      VERSION="$2"
      shift 2
      ;;
    *)
      if [[ -z "$VERSION" ]]; then
        VERSION="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  VERSION="$("${SCRIPT_DIR}/calculate-semver.sh" --format version)"
fi

TAG="v${VERSION#v}"

# Configurar identidad de git si no está definida en el entorno de CI
if ! git config user.name >/dev/null 2>&1; then
  git config user.name "CircleGuard Release Bot"
fi
if ! git config user.email >/dev/null 2>&1; then
  git config user.email "bot@circleguard.edu"
fi

# Verificar si el tag ya existe localmente
if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "El tag '${TAG}' ya existe en el repositorio local."
else
  echo "Creando tag anotado '${TAG}'..."
  git tag -a "${TAG}" -m "Release ${TAG} [skip ci]"
  echo "Tag '${TAG}' creado exitosamente."
fi

# Publicar el tag al remoto si se solicitó --push
if [[ "$DO_PUSH" == "true" ]]; then
  echo "Publicando tag '${TAG}' en origin..."
  git push origin "${TAG}"
  echo "Tag '${TAG}' publicado exitosamente en origin."
fi
