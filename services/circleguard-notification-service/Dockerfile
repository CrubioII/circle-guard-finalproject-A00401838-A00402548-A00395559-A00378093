# syntax=docker/dockerfile:1.7
# =============================================================================
# CircleGuard :: notification-service  (US-06)
# Multi-stage, non-root image. Multi-channel notification dispatcher (push, email, SMS).
#
# Build (the build context MUST be the monorepo root):
#   docker build -f services/circleguard-notification-service/Dockerfile -t circleguard/notification-service:<version> .
# =============================================================================

ARG GRADLE_IMAGE=gradle:8.14-jdk21-alpine
ARG JRE_IMAGE=eclipse-temurin:21-jre-alpine

# -----------------------------------------------------------------------------
# Stage 1 - build: compile with JDK 21 + Gradle 8.14 and extract Spring Boot layers
# -----------------------------------------------------------------------------
FROM ${GRADLE_IMAGE} AS build

ARG SERVICE=circleguard-notification-service
WORKDIR /workspace

# Root Gradle build (settings + shared subprojects config) and this service's build script only.
COPY settings.gradle.kts build.gradle.kts gradle.properties ./
COPY services/${SERVICE}/build.gradle.kts services/${SERVICE}/

# settings.gradle.kts includes all 8 services: create empty dirs for the ones not copied
# into this image so Gradle does not warn about missing project directories.
RUN for s in auth identity promotion notification form file gateway dashboard; do \
      mkdir -p "services/circleguard-$s-service"; \
    done

COPY services/${SERVICE}/src/main services/${SERVICE}/src/main

# Tests run in the CI pipeline, not inside the image build.
# The BuildKit cache mount keeps Gradle dependencies between builds (shared by all 8 services).
RUN --mount=type=cache,id=circleguard-gradle,target=/home/gradle/.gradle,sharing=locked \
    gradle ":services:${SERVICE}:bootJar" --no-daemon --console=plain -x test \
 && cp "services/${SERVICE}/build/libs/${SERVICE}-1.0.0-SNAPSHOT.jar" /workspace/app.jar \
 && java -Djarmode=layertools -jar /workspace/app.jar extract --destination /workspace/extracted

# -----------------------------------------------------------------------------
# Stage 2 - runtime: JRE 21 on Alpine, unprivileged user, read-only app files
# -----------------------------------------------------------------------------
FROM ${JRE_IMAGE} AS runtime

ARG APP_UID=10001
ARG APP_GID=10001

LABEL org.opencontainers.image.title="circleguard-notification-service" \
      org.opencontainers.image.description="CircleGuard notification-service - Multi-channel notification dispatcher (push, email, SMS)." \
      org.opencontainers.image.vendor="CircleGuard" \
      org.opencontainers.image.source="https://github.com/CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093"

# Dedicated unprivileged system user/group (circleguard), no login shell, no home directory.
RUN addgroup -S -g "${APP_GID}" circleguard \
 && adduser -S -D -H -u "${APP_UID}" -G circleguard -s /sbin/nologin circleguard

WORKDIR /app

# Spring Boot layers ordered from least to most frequently changing (better layer reuse).
# Files stay owned by root and are read-only for the app user: the process cannot modify its own code.
COPY --from=build /workspace/extracted/dependencies/ ./
COPY --from=build /workspace/extracted/spring-boot-loader/ ./
COPY --from=build /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build /workspace/extracted/application/ ./

ENV SERVER_PORT=8082 \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"

# Run as circleguard. Numeric UID:GID so Kubernetes 'runAsNonRoot' can verify it is not root.
USER ${APP_UID}:${APP_GID}

EXPOSE 8082

# Liveness group from Spring Boot Actuator (management.endpoint.health.probes.enabled=true).
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${SERVER_PORT}/actuator/health/liveness" || exit 1

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
