#!/usr/bin/env bash
# jenkins/test/run-notify-validation.sh
# Historia de Usuario: US-14 (SCRUM-26) - CA1 / Subtarea SCRUM-70
# Propósito: Ejecutar de forma reproducible la validación del paso notifyPipeline
# (mensaje de Discord, política de notificación y manejo de errores) sin Jenkins ni red.
#
# Alternativa sin instalar Groovy: ./gradlew validateJenkinsNotifications

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GROOVY_VERSION="4.0.21"
GROOVY_CACHE_DIR="${HOME}/.cache/circleguard-groovy"
MAVEN_BASE="https://repo1.maven.org/maven2/org/apache/groovy"

cd "${REPO_ROOT}"

if command -v groovy >/dev/null 2>&1; then
    echo "[US-14] Ejecutando validacion de notifyPipeline con el binario groovy del sistema..."
    groovy -Dcircleguard.repoRoot="${REPO_ROOT}" jenkins/test/validateNotifyPipeline.groovy
else
    mkdir -p "${GROOVY_CACHE_DIR}"
    CLASSPATH_JARS=""
    for artifact in groovy groovy-json; do
        jar="${GROOVY_CACHE_DIR}/${artifact}-${GROOVY_VERSION}.jar"
        if [[ ! -f "${jar}" ]]; then
            echo "[US-14] Descargando ${artifact} ${GROOVY_VERSION} desde Maven Central..."
            curl -fsSL "${MAVEN_BASE}/${artifact}/${GROOVY_VERSION}/${artifact}-${GROOVY_VERSION}.jar" -o "${jar}"
        fi
        CLASSPATH_JARS="${CLASSPATH_JARS:+${CLASSPATH_JARS}:}${jar}"
    done
    echo "[US-14] Ejecutando validacion de notifyPipeline con Java + Groovy ${GROOVY_VERSION}..."
    java -Dcircleguard.repoRoot="${REPO_ROOT}" -cp "${CLASSPATH_JARS}" groovy.ui.GroovyMain jenkins/test/validateNotifyPipeline.groovy
fi
