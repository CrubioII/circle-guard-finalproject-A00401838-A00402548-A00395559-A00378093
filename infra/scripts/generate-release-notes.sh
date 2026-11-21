#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Generador automatico de Release Notes y Changelog (US-18 / SCRUM-30)
#
# Extrae el historial de commits desde el tag previo hasta HEAD, clasifica los
# cambios segun Conventional Commits y genera:
#   1. docs/release-notes/RELEASE_NOTES_v<version>.md
#   2. CHANGELOG.md en la raiz del monorepo
#   3. (Opcional) Publicacion a GitHub Releases mediante REST API
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VERSION="${1:-}"
PUBLISH_GITHUB="false"
RELEASE_DATE="$(date +%Y-%m-%d)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github)
      PUBLISH_GITHUB="true"
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

cd "${ROOT_DIR}"

if [[ -z "${VERSION}" ]]; then
  VERSION="$("${SCRIPT_DIR}/calculate-semver.sh" --format version)"
fi

VERSION_CLEAN="${VERSION#v}"
TAG="v${VERSION_CLEAN}"

# Obtener tag anterior
LAST_TAG=$(git tag -l "v[0-9]*.[0-9]*.[0-9]*" --sort=-v:refname | grep -v "^${TAG}$" | head -n1 || true)

if [[ -n "${LAST_TAG}" ]]; then
  RANGE="${LAST_TAG}..HEAD"
  PREVIOUS_TAG_INFO="Cambios incluidos desde ${LAST_TAG}:"
else
  RANGE="HEAD"
  PREVIOUS_TAG_INFO="Liberacion inicial con todos los cambios acumulados hasta la fecha:"
fi

BREAKING_LIST=()
FEAT_LIST=()
FIX_LIST=()
PERF_LIST=()
REFACTOR_LIST=()
INFRA_LIST=()
DOCS_LIST=()
CHORE_LIST=()

while IFS= read -r commit_hash; do
  [[ -z "$commit_hash" ]] && continue
  subject=$(git log -1 --format="%s" "$commit_hash")
  short_hash=$(git log -1 --format="%h" "$commit_hash")
  entry="- \`${short_hash}\` ${subject}"

  # Comprobar si el cuerpo contiene breaking change
  body=$(git log -1 --format="%b" "$commit_hash")
  if [[ "$subject" =~ ^[a-zA-Z0-9_-]+(\([^\)]+\))?!: ]] || [[ "$body" =~ BREAKING[[:space:]-]CHANGE: ]]; then
    BREAKING_LIST+=("${entry}")
  fi

  if [[ "$subject" =~ ^feat(\([^\)]+\))?: ]]; then
    FEAT_LIST+=("${entry}")
  elif [[ "$subject" =~ ^fix(\([^\)]+\))?: ]]; then
    FIX_LIST+=("${entry}")
  elif [[ "$subject" =~ ^perf(\([^\)]+\))?: ]]; then
    PERF_LIST+=("${entry}")
  elif [[ "$subject" =~ ^refactor(\([^\)]+\))?: ]]; then
    REFACTOR_LIST+=("${entry}")
  elif [[ "$subject" =~ ^(ci|build|infra|docker)(\([^\)]+\))?: ]]; then
    INFRA_LIST+=("${entry}")
  elif [[ "$subject" =~ ^docs(\([^\)]+\))?: ]]; then
    DOCS_LIST+=("${entry}")
  else
    CHORE_LIST+=("${entry}")
  fi
done < <(git log --no-merges "${RANGE}" --format="%H" 2>/dev/null || true)

# Construir contenido markdown del Release
NOTES_CONTENT="# Release ${TAG} (${RELEASE_DATE})

${PREVIOUS_TAG_INFO}
"

if [[ ${#BREAKING_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Cambios que rompen compatibilidad (Breaking Changes)
"
  for item in "${BREAKING_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

if [[ ${#FEAT_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Nuevas funcionalidades (Features)
"
  for item in "${FEAT_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

if [[ ${#FIX_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Correcciones de defectos (Bug Fixes)
"
  for item in "${FIX_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

if [[ ${#PERF_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Mejoras de rendimiento (Performance)
"
  for item in "${PERF_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

if [[ ${#REFACTOR_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Refactorizaciones
"
  for item in "${REFACTOR_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

if [[ ${#INFRA_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Infraestructura, Docker y CI/CD
"
  for item in "${INFRA_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

if [[ ${#DOCS_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Documentacion
"
  for item in "${DOCS_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

if [[ ${#CHORE_LIST[@]} -gt 0 ]]; then
  NOTES_CONTENT+="
## Mantenimiento y tareas menores
"
  for item in "${CHORE_LIST[@]}"; do
    NOTES_CONTENT+="${item}
"
  done
fi

NOTES_CONTENT+="
## Artefactos e imagenes inmutables asociadas

Las siguientes imagenes fueron construidas y etiquetadas para este release:
- \`18.117.90.15:5000/circleguard/auth:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/identity:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/promotion:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/form:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/gateway:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/notification:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/file:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/dashboard:${VERSION_CLEAN}\`
- \`18.117.90.15:5000/circleguard/mobile:${VERSION_CLEAN}\`
"

# 1. Escribir archivo individual en docs/release-notes/
mkdir -p "${ROOT_DIR}/docs/release-notes"
RELEASE_FILE="${ROOT_DIR}/docs/release-notes/RELEASE_NOTES_${TAG}.md"
printf "%s" "${NOTES_CONTENT}" > "${RELEASE_FILE}"
echo "Release notes generadas en: ${RELEASE_FILE}"

# 2. Actualizar o crear CHANGELOG.md en la raiz
CHANGELOG_FILE="${ROOT_DIR}/CHANGELOG.md"
HEADER="# Registro de cambios (Changelog) - CircleGuard

Todas las modificaciones notables de este proyecto estan documentadas en este archivo siguiendo la especificacion Keep a Changelog y SemVer.
"

if [[ ! -f "${CHANGELOG_FILE}" ]]; then
  printf "%s\n\n%s\n" "${HEADER}" "${NOTES_CONTENT}" > "${CHANGELOG_FILE}"
  echo "CHANGELOG.md creado exitosamente."
else
  # Si la seccion del tag ya existe en el archivo, se actualiza
  if grep -q "# Release ${TAG} " "${CHANGELOG_FILE}"; then
    echo "La version ${TAG} ya se encontraba registrada en CHANGELOG.md."
  else
    TEMP_CHANGELOG=$(mktemp)
    # Extraer encabezado existente y colocar la nueva seccion al inicio
    printf "%s\n\n%s\n\n" "${HEADER}" "${NOTES_CONTENT}" > "${TEMP_CHANGELOG}"
    tail -n +4 "${CHANGELOG_FILE}" >> "${TEMP_CHANGELOG}"
    mv "${TEMP_CHANGELOG}" "${CHANGELOG_FILE}"
    echo "CHANGELOG.md actualizado con la seccion ${TAG}."
  fi
fi

# 3. Opcional: Publicar a GitHub Releases si se solicito y existe token
if [[ "${PUBLISH_GITHUB}" == "true" && -n "${GITHUB_TOKEN:-}" ]]; then
  REPO="${CIRCLEGUARD_REPOSITORY:-CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093}"
  API_URL="https://api.github.com/repos/${REPO}/releases"

  PAYLOAD=$(python3 -c "import json, sys; print(json.dumps({
    'tag_name': '${TAG}',
    'target_commitish': 'main',
    'name': 'Release ${TAG}',
    'body': sys.stdin.read(),
    'draft': False,
    'prerelease': False
  }))" <<< "${NOTES_CONTENT}")

  echo "Publicando release ${TAG} en GitHub (${REPO})..."
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "${PAYLOAD}")

  HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
  if [[ "${HTTP_CODE}" == "201" || "${HTTP_CODE}" == "200" ]]; then
    echo "Release ${TAG} publicado exitosamente en GitHub."
  else
    echo "Aviso: No se pudo crear release en GitHub (HTTP ${HTTP_CODE}). Contenido guardado localmente."
  fi
fi
