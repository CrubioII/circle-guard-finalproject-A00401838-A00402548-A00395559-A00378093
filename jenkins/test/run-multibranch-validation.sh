#!/usr/bin/env bash
# jenkins/test/run-multibranch-validation.sh
# Historia de Usuario: US-30 (SCRUM-113 / SCRUM-56 / SCRUM-57) — CA1, CA2, CA3
# Propósito: Ejecutar de forma 100% reproducible la suite de validación del
# Jenkinsfile Multibranch, el plan PR/main, la publicación de estados en GitHub,
# la configuración JCasC y el script del webhook.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GROOVY_VERSION="4.0.21"
GROOVY_CACHE_DIR="${HOME}/.cache/circleguard-groovy"
GROOVY_CORE_JAR="${GROOVY_CACHE_DIR}/groovy-${GROOVY_VERSION}.jar"
GROOVY_JSON_JAR="${GROOVY_CACHE_DIR}/groovy-json-${GROOVY_VERSION}.jar"

cd "${REPO_ROOT}"

if command -v groovy >/dev/null 2>&1; then
    echo "[US-30] Ejecutando validacion con binario groovy del sistema..."
    groovy jenkins/test/validateMultibranchPipeline.groovy
else
    mkdir -p "${GROOVY_CACHE_DIR}"
    for artifact in "groovy:${GROOVY_CORE_JAR}" "groovy-json:${GROOVY_JSON_JAR}"; do
        module="${artifact%%:*}"
        destination="${artifact##*:}"
        if [[ ! -f "${destination}" ]]; then
            echo "[US-30] Descargando ${module} ${GROOVY_VERSION} desde Maven Central..."
            curl -fsSL "https://repo1.maven.org/maven2/org/apache/groovy/${module}/${GROOVY_VERSION}/${module}-${GROOVY_VERSION}.jar" -o "${destination}"
        fi
    done
    echo "[US-30] Ejecutando validacion reproducible con Java + Groovy ${GROOVY_VERSION}..."
    java -cp "${GROOVY_CORE_JAR}:${GROOVY_JSON_JAR}" groovy.ui.GroovyMain jenkins/test/validateMultibranchPipeline.groovy
fi
