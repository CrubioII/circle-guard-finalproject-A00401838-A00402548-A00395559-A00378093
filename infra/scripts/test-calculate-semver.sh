#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Pruebas automatizadas para calculate-semver.sh (US-12)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALCULATE_SCRIPT="${SCRIPT_DIR}/calculate-semver.sh"
TEMP_REPO=$(mktemp -d -t cg-semver-test-XXXXXX)

cleanup() {
  rm -rf "${TEMP_REPO}"
}
trap cleanup EXIT

echo "Ejecutando pruebas de calculate-semver.sh en: ${TEMP_REPO}"
cd "${TEMP_REPO}"
git init -b main
git config user.name "Test Bot"
git config user.email "test@circleguard.edu"

# Caso 1: Repositorio inicial con commit feat
echo "test 1" > file1.txt
git add file1.txt
git commit -m "feat(core): initial feature implementation"
V1=$("${CALCULATE_SCRIPT}" --format version)
if [[ "${V1}" != "0.1.0" ]]; then
  echo "FALLO Caso 1: esperado '0.1.0', obtenido '${V1}'" >&2
  exit 1
fi
echo "Caso 1 superado: repositorio inicial con feat genera 0.1.0"

# Crear tag v0.1.0
git tag -a "v0.1.0" -m "Release v0.1.0"

# Caso 2: Nuevo commit fix -> incremento PATCH (0.1.1)
echo "test 2" > file2.txt
git add file2.txt
git commit -m "fix(auth): handle null token exception"
V2=$("${CALCULATE_SCRIPT}" --format version)
if [[ "${V2}" != "0.1.1" ]]; then
  echo "FALLO Caso 2: esperado '0.1.1', obtenido '${V2}'" >&2
  exit 1
fi
echo "Caso 2 superado: commit fix incrementa a 0.1.1"

# Crear tag v0.1.1
git tag -a "v0.1.1" -m "Release v0.1.1"

# Caso 3: Nuevo commit feat -> incremento MINOR (0.2.0)
echo "test 3" > file3.txt
git add file3.txt
git commit -m "feat(identity): add biometric verification"
V3=$("${CALCULATE_SCRIPT}" --format version)
if [[ "${V3}" != "0.2.0" ]]; then
  echo "FALLO Caso 3: esperado '0.2.0', obtenido '${V3}'" >&2
  exit 1
fi
echo "Caso 3 superado: commit feat incrementa a 0.2.0"

# Crear tag v0.2.0
git tag -a "v0.2.0" -m "Release v0.2.0"

# Caso 4: Nuevo commit con breaking change -> incremento MAJOR (1.0.0)
echo "test 4" > file4.txt
git add file4.txt
git commit -m "feat(gateway)!: remove legacy v1 endpoints"
V4=$("${CALCULATE_SCRIPT}" --format version)
if [[ "${V4}" != "1.0.0" ]]; then
  echo "FALLO Caso 4: esperado '1.0.0', obtenido '${V4}'" >&2
  exit 1
fi
echo "Caso 4 superado: breaking change incrementa a 1.0.0"

# Caso 5: Exportación a archivo env
EXPORT_FILE="${TEMP_REPO}/export.env"
"${CALCULATE_SCRIPT}" --export "${EXPORT_FILE}" --format env >/dev/null
if ! grep -q "APP_VERSION=1.0.0" "${EXPORT_FILE}" || ! grep -q "GIT_TAG=v1.0.0" "${EXPORT_FILE}"; then
  echo "FALLO Caso 5: archivo de exportación no contiene variables esperadas" >&2
  exit 1
fi
echo "Caso 5 superado: exportación de variables de entorno correcta"

echo "Todas las pruebas de SemVer (US-12) finalizaron exitosamente."
