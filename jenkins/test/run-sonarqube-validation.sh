#!/usr/bin/env bash
# jenkins/test/run-sonarqube-validation.sh
# Historia de Usuario: US-10 (SCRUM-22 / SCRUM-58 / SCRUM-59 / SCRUM-60) — CA1, CA2, CA3
# Propósito: Ejecutar de forma 100% reproducible la suite de validación de
# Gradle + JaCoCo + SonarQube Quality Gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GROOVY_VERSION="4.0.21"
GROOVY_CACHE_DIR="${HOME}/.cache/circleguard-groovy"
GROOVY_CORE_JAR="${GROOVY_CACHE_DIR}/groovy-${GROOVY_VERSION}.jar"
GROOVY_JSON_JAR="${GROOVY_CACHE_DIR}/groovy-json-${GROOVY_VERSION}.jar"

cd "${REPO_ROOT}"

if command -v groovy >/dev/null 2>&1; then
    echo "[US-10] Ejecutando validacion con binario groovy del sistema..."
    groovy jenkins/test/validateSonarQualityGate.groovy
else
    mkdir -p "${GROOVY_CACHE_DIR}"
    for artifact in "groovy:${GROOVY_CORE_JAR}" "groovy-json:${GROOVY_JSON_JAR}"; do
        module="${artifact%%:*}"
        destination="${artifact##*:}"
        if [[ ! -f "${destination}" ]]; then
            echo "[US-10] Descargando ${module} ${GROOVY_VERSION} desde Maven Central..."
            curl -fsSL "https://repo1.maven.org/maven2/org/apache/groovy/${module}/${GROOVY_VERSION}/${module}-${GROOVY_VERSION}.jar" -o "${destination}"
        fi
    done
    echo "[US-10] Ejecutando validacion reproducible con Java + Groovy ${GROOVY_VERSION}..."
    java -cp "${GROOVY_CORE_JAR}:${GROOVY_JSON_JAR}" groovy.ui.GroovyMain jenkins/test/validateSonarQualityGate.groovy
fi
