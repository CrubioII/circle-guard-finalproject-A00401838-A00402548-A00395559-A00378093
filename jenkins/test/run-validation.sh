#!/usr/bin/env bash
# jenkins/test/run-validation.sh
# Historia de Usuario: US-09 (SCRUM-21 / SCRUM-55) - CA3
# Propósito: Ejecutar de forma 100% reproducible la batería de pruebas de la
# Shared Library de Jenkins (detectChangedServices y pipelineUtils).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GROOVY_VERSION="4.0.21"
GROOVY_CACHE_DIR="${HOME}/.cache/circleguard-groovy"
GROOVY_JAR="${GROOVY_CACHE_DIR}/groovy-${GROOVY_VERSION}.jar"

cd "${REPO_ROOT}"

if command -v groovy >/dev/null 2>&1; then
    echo "[US-09] Ejecutando validacion con binario groovy del sistema..."
    groovy jenkins/test/validateSharedLibrary.groovy
else
    mkdir -p "${GROOVY_CACHE_DIR}"
    if [[ ! -f "${GROOVY_JAR}" ]]; then
        echo "[US-09] Descargando runtime ligero de Apache Groovy ${GROOVY_VERSION} desde Maven Central..."
        curl -fsSL "https://repo1.maven.org/maven2/org/apache/groovy/groovy/${GROOVY_VERSION}/groovy-${GROOVY_VERSION}.jar" -o "${GROOVY_JAR}"
    fi
    echo "[US-09] Ejecutando validacion reproducible con Java + Groovy ${GROOVY_VERSION}..."
    java -cp "${GROOVY_JAR}" groovy.ui.GroovyMain jenkins/test/validateSharedLibrary.groovy
fi
