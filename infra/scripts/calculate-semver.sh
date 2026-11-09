#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Cálculo automático de Versionado Semántico (SemVer) (US-12 / SCRUM-24)
#
# Analiza los mensajes de commit según la especificación Conventional Commits v1.0.0
# desde el último tag de Git ('vX.Y.Z') hasta HEAD para determinar el incremento:
#   - MAJOR (X.0.0): Commits con 'BREAKING CHANGE:' o '<tipo>(<scope>)!:'
#   - MINOR (0.X.0): Commits de tipo 'feat' o 'feat(<scope>):'
#   - PATCH (0.0.X): Commits de tipo 'fix', 'perf', 'refactor' o 'build'
#
# Si no existe ningún tag previo en el repositorio, la versión base dinámica es '0.1.0'
# (o '1.0.0' si se detecta un cambio mayor).
# =============================================================================
set -euo pipefail

FORMAT="version"
OUTPUT_FILE=""
INITIAL_VERSION="0.1.0"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --export)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --initial)
      INITIAL_VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      echo "Uso: $0 [--format version|tag|json|env] [--export <archivo>] [--initial <X.Y.Z>]"
      exit 0
      ;;
    *)
      echo "Opción no reconocida: $1" >&2
      exit 1
      ;;
  esac
done

# 1. Obtener el último tag anotado o ligero que cumpla el patrón vX.Y.Z
LAST_TAG=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  LAST_TAG=$(git tag -l "v[0-9]*.[0-9]*.[0-9]*" --sort=-v:refname | head -n1 || true)
fi

# 2. Determinar rango de commits a examinar
COMMIT_RANGE=""
if [[ -n "${LAST_TAG}" ]]; then
  # Si el HEAD actual apunta exactamente al tag más reciente, no hay commits nuevos
  HEAD_REV=$(git rev-parse HEAD 2>/dev/null || true)
  TAG_REV=$(git rev-parse "${LAST_TAG}^{commit}" 2>/dev/null || true)
  if [[ -n "${HEAD_REV}" && "${HEAD_REV}" == "${TAG_REV}" ]]; then
    COMMIT_RANGE=""
  else
    COMMIT_RANGE="${LAST_TAG}..HEAD"
  fi
else
  COMMIT_RANGE="HEAD"
fi

# 3. Analizar los commits y clasificar el tipo de incremento
BUMP="none"
HAS_BREAKING=0
HAS_FEAT=0
HAS_PATCH=0
TOTAL_COMMITS=0

if [[ -n "${COMMIT_RANGE}" ]] && git rev-parse --verify HEAD >/dev/null 2>&1; then
  # Se extrae sujeto y cuerpo de cada commit delimitado por un separador
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "===CG_COMMIT_START===" ]]; then
      TOTAL_COMMITS=$((TOTAL_COMMITS + 1))
      continue
    fi

    # Detección de Breaking Changes
    if [[ "$line" =~ BREAKING[[:space:]-]CHANGE: ]] || [[ "$line" =~ ^[a-zA-Z0-9_-]+(\([^\)]+\))?!: ]]; then
      HAS_BREAKING=1
      continue
    fi

    # Detección de nueva funcionalidad (feat -> MINOR)
    if [[ "$line" =~ ^feat(\([^\)]+\))?: ]]; then
      HAS_FEAT=1
      continue
    fi

    # Detección de correcciones, rendimiento o refactor (PATCH)
    if [[ "$line" =~ ^(fix|perf|refactor|build)(\([^\)]+\))?: ]]; then
      HAS_PATCH=1
      continue
    fi
  done < <(git log --no-merges "${COMMIT_RANGE}" --pretty=format:"===CG_COMMIT_START===%n%s%n%b" 2>/dev/null || true)
fi

if [[ $HAS_BREAKING -eq 1 ]]; then
  BUMP="major"
elif [[ $HAS_FEAT -eq 1 ]]; then
  BUMP="minor"
elif [[ $HAS_PATCH -eq 1 ]]; then
  BUMP="patch"
elif [[ $TOTAL_COMMITS -gt 0 ]]; then
  BUMP="patch"
else
  BUMP="none"
fi

# 4. Calcular los componentes MAJOR, MINOR y PATCH
MAJOR=0
MINOR=0
PATCH=0

if [[ -n "${LAST_TAG}" ]]; then
  RAW_VERSION="${LAST_TAG#v}"
  MAJOR=$(echo "${RAW_VERSION}" | cut -d. -f1)
  MINOR=$(echo "${RAW_VERSION}" | cut -d. -f2)
  PATCH=$(echo "${RAW_VERSION}" | cut -d. -f3 | cut -d- -f1)

  case "$BUMP" in
    major)
      MAJOR=$((MAJOR + 1))
      MINOR=0
      PATCH=0
      ;;
    minor)
      MINOR=$((MINOR + 1))
      PATCH=0
      ;;
    patch)
      PATCH=$((PATCH + 1))
      ;;
    none)
      # Mantener la versión actual del último tag
      ;;
  esac
else
  # Sin tags previos: establecer versión inicial según el primer incremento detectado
  INIT_MAJOR=$(echo "${INITIAL_VERSION}" | cut -d. -f1)
  INIT_MINOR=$(echo "${INITIAL_VERSION}" | cut -d. -f2)
  INIT_PATCH=$(echo "${INITIAL_VERSION}" | cut -d. -f3)

  case "$BUMP" in
    major)
      MAJOR=1
      MINOR=0
      PATCH=0
      ;;
    minor)
      MAJOR=0
      MINOR=1
      PATCH=0
      ;;
    patch)
      MAJOR=0
      MINOR=1
      PATCH=0
      ;;
    none)
      MAJOR=${INIT_MAJOR}
      MINOR=${INIT_MINOR}
      PATCH=${INIT_PATCH}
      ;;
  esac
fi

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
NEW_TAG="v${NEW_VERSION}"

# 5. Exportar a archivo si se especificó --export
if [[ -n "${OUTPUT_FILE}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  cat <<EOF > "${OUTPUT_FILE}"
APP_VERSION=${NEW_VERSION}
SEMVER_VERSION=${NEW_VERSION}
GIT_TAG=${NEW_TAG}
IMAGE_TAG=${NEW_VERSION}
SEMVER_BUMP=${BUMP}
LAST_TAG=${LAST_TAG:-none}
TOTAL_COMMITS_ANALYZED=${TOTAL_COMMITS}
EOF
fi

# 6. Salida en el formato solicitado
case "$FORMAT" in
  version)
    echo "${NEW_VERSION}"
    ;;
  tag)
    echo "${NEW_TAG}"
    ;;
  json)
    cat <<EOF
{
  "version": "${NEW_VERSION}",
  "tag": "${NEW_TAG}",
  "bump": "${BUMP}",
  "lastTag": "${LAST_TAG:-null}",
  "commitsAnalyzed": ${TOTAL_COMMITS}
}
EOF
    ;;
  env)
    cat <<EOF
APP_VERSION=${NEW_VERSION}
SEMVER_VERSION=${NEW_VERSION}
GIT_TAG=${NEW_TAG}
IMAGE_TAG=${NEW_VERSION}
SEMVER_BUMP=${BUMP}
LAST_TAG=${LAST_TAG:-none}
EOF
    ;;
  *)
    echo "Formato desconocido: ${FORMAT}" >&2
    exit 1
    ;;
esac
