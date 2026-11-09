# =============================================================================
# Dockerfile personalizado de Jenkins Controller/Agent — CircleGuard (US-04 / SCRUM-40)
# Base: Jenkins LTS sobre OpenJDK 21
# Incluye:
#   - Java 21 (Eclipse Temurin JDK 21 incluido en la imagen base)
#   - Gradle 8.5 (además del soporte para ./gradlew del monorepo)
#   - Docker CLI + Docker Compose v2 plugin (para construir y publicar imágenes)
#   - Node.js 20 LTS + npm + dependencias del sistema para Playwright (Chromium headless)
#   - Plugins de Jenkins preinstalados vía jenkins-plugin-cli (JCasC, Multibranch, JaCoCo, SonarQube)
# =============================================================================
FROM jenkins/jenkins:2.580.2-jdk21

LABEL org.opencontainers.image.title="CircleGuard Jenkins CI Controller & Agent" \
      org.opencontainers.image.description="Servidor Jenkins con JDK 21, Gradle 8.5, Docker CLI, Node.js 20 y dependencias de Playwright" \
      org.opencontainers.image.version="2.580.2-jdk21"

ARG GRADLE_VERSION=8.5
ARG NODE_MAJOR=20

USER root

# 1. Instalar paquetes base, Docker CLI, Node.js 20 LTS y librerías del sistema para Playwright
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        unzip \
        xz-utils \
        git \
        # Cliente SSH/SCP: despliegue a los nodos dev/stage y túneles E2E (US-13)
        openssh-client \
        # Dependencias de sistema requeridas por Playwright (Chromium / WebKit / Firefox headless)
        libnss3 \
        libnspr4 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libcups2 \
        libdrm2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libxrandr2 \
        libgbm1 \
        libasound2 \
        libpango-1.0-0 \
        libcairo2 \
        libatspi2.0-0 \
        libxshmfence1 \
        fonts-liberation \
        fonts-noto-color-emoji; \
    # Repositorio oficial de Docker para instalar docker-ce-cli y docker-compose-plugin
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    chmod a+r /etc/apt/keyrings/docker.gpg; \
    . /etc/os-release; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list; \
    # Repositorio NodeSource para Node.js 20 LTS
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        nodejs; \
    rm -rf /var/lib/apt/lists/*

# 2. Instalar Gradle de forma global en /opt/gradle
RUN set -eux; \
    curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip; \
    mkdir -p /opt/gradle; \
    unzip -q /tmp/gradle.zip -d /opt/gradle; \
    ln -sf "/opt/gradle/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle; \
    rm -f /tmp/gradle.zip; \
    gradle --version

# 3. Preinstalar los plugins requeridos por el pipeline y JCasC
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# 4. Preparar directorio para configuración JCasC
RUN mkdir -p /var/jenkins_home/casc_configs && chown -R jenkins:jenkins /var/jenkins_home/casc_configs

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
    CASC_JENKINS_CONFIG="/var/jenkins_home/casc_configs/jenkins.yaml" \
    PLAYWRIGHT_BROWSERS_PATH="/var/jenkins_home/.cache/ms-playwright"

USER jenkins

EXPOSE 8080 50000

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD curl -fsS http://localhost:8080/login >/dev/null || exit 1
