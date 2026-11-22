# =============================================================================
# Dockerfile personalizado de Jenkins Controller/Agent — CircleGuard (US-04 / SCRUM-40)
# Base: Jenkins LTS sobre OpenJDK 21
# Incluye:
#   - Java 21 (Eclipse Temurin JDK 21 incluido en la imagen base)
#   - Gradle 8.5 (además del soporte para ./gradlew del monorepo)
#   - Docker CLI + Docker Compose v2 plugin (para construir y publicar imágenes)
#   - Node.js 20 LTS + npm + dependencias del sistema para Playwright (Chromium headless)
#   - Plugins de Jenkins preinstalados vía jenkins-plugin-cli (JCasC, Multibranch, JaCoCo, SonarQube)
#   - Terraform (US-22) y Trivy con sus plantillas JUnit/HTML (US-38), con versión fija y
#     verificación SHA-256 del binario descargado
# =============================================================================
FROM jenkins/jenkins:2.580.2-jdk21

LABEL org.opencontainers.image.title="CircleGuard Jenkins CI Controller & Agent" \
      org.opencontainers.image.description="Servidor Jenkins con JDK 21, Gradle 8.5, Docker CLI, Node.js 20 y dependencias de Playwright" \
      org.opencontainers.image.version="2.580.2-jdk21"

ARG GRADLE_VERSION=8.5
ARG NODE_MAJOR=20
# US-22 / US-38: herramientas de plataforma con versión fija.
ARG TERRAFORM_VERSION=1.11.4
# 0.69.3: versión segura publicada con releases inmutables (las anteriores a 0.69.2 se retiraron de GitHub).
ARG TRIVY_VERSION=0.69.3

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

# 2b. US-22 / US-38: terraform y trivy. Cada descarga se compara con el
#     archivo de checksums publicado por el proveedor antes de instalarse.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in amd64) trivy_arch=64bit ;; arm64) trivy_arch=ARM64 ;; *) echo "arquitectura no soportada: ${arch}"; exit 1 ;; esac; \
    cd /tmp; \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip"; \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep " terraform_${TERRAFORM_VERSION}_linux_${arch}.zip$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" terraform -d /usr/local/bin; \
    curl -fsSLO "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${trivy_arch}.tar.gz"; \
    curl -fsSLO "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt"; \
    grep " trivy_${TRIVY_VERSION}_Linux-${trivy_arch}.tar.gz$" "trivy_${TRIVY_VERSION}_checksums.txt" | sha256sum -c -; \
    mkdir -p /tmp/trivy /usr/local/share/trivy/templates; \
    tar -xzf "trivy_${TRIVY_VERSION}_Linux-${trivy_arch}.tar.gz" -C /tmp/trivy; \
    install -m 0755 /tmp/trivy/trivy /usr/local/bin/trivy; \
    cp /tmp/trivy/contrib/*.tpl /usr/local/share/trivy/templates/; \
    rm -rf /tmp/terraform_* /tmp/trivy*; \
    terraform version; trivy --version

# 3. Preinstalar los plugins requeridos por el pipeline y JCasC
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# 4. Preparar directorio para configuración JCasC
RUN mkdir -p /var/jenkins_home/casc_configs && chown -R jenkins:jenkins /var/jenkins_home/casc_configs

# 5. US-31: entrypoint que no arranca Jenkins si faltan los secretos de las cuentas
COPY --chmod=0755 cg-entrypoint.sh /usr/local/bin/cg-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/cg-entrypoint.sh"]

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
    CASC_JENKINS_CONFIG="/var/jenkins_home/casc_configs/jenkins.yaml" \
    PLAYWRIGHT_BROWSERS_PATH="/var/jenkins_home/.cache/ms-playwright" \
    TRIVY_CACHE_DIR="/var/jenkins_home/.cache/trivy" \
    TRIVY_TEMPLATES_DIR="/usr/local/share/trivy/templates"

USER jenkins

EXPOSE 8080 50000

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD curl -fsS http://localhost:8080/login >/dev/null || exit 1
