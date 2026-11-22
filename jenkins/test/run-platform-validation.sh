#!/usr/bin/env bash
# jenkins/test/run-platform-validation.sh
# Historias de Usuario: US-22, US-38, US-39 y US-28.
# Ejecuta jenkins/test/validatePlatformFlow.groovy con groovy del sistema o con Java + Groovy 4
# descargado de Maven Central (mismo mecanismo que run-multibranch-validation.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GROOVY_VERSION="4.0.21"
GROOVY_CACHE_DIR="${HOME}/.cache/circleguard-groovy"
GROOVY_CORE_JAR="${GROOVY_CACHE_DIR}/groovy-${GROOVY_VERSION}.jar"
GROOVY_JSON_JAR="${GROOVY_CACHE_DIR}/groovy-json-${GROOVY_VERSION}.jar"

cd "${REPO_ROOT}"
if command -v groovy >/dev/null 2>&1; then
    groovy jenkins/test/validatePlatformFlow.groovy
else
    mkdir -p "${GROOVY_CACHE_DIR}"
    for artifact in "groovy:${GROOVY_CORE_JAR}" "groovy-json:${GROOVY_JSON_JAR}"; do
        module="${artifact%%:*}"
        destination="${artifact##*:}"
        if [[ ! -f "${destination}" ]]; then
            curl -fsSL "https://repo1.maven.org/maven2/org/apache/groovy/${module}/${GROOVY_VERSION}/${module}-${GROOVY_VERSION}.jar" -o "${destination}"
        fi
    done
    java -cp "${GROOVY_CORE_JAR}:${GROOVY_JSON_JAR}" groovy.ui.GroovyMain jenkins/test/validatePlatformFlow.groovy
fi
