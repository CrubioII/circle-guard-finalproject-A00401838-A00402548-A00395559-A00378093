# syntax=docker/dockerfile:1.7
# =============================================================================
# CircleGuard :: web-client (mobile/) - US-07 / SCRUM-19
# Multi-stage, non-root image for the Expo (React Native Web) SPA client.
#
# Build (build context is the mobile/ directory):
#   docker build -f mobile/Dockerfile -t circleguard/web-client:<version> mobile
# =============================================================================

ARG NODE_IMAGE=node:20-alpine
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.31.7-alpine3.24

# -----------------------------------------------------------------------------
# Stage 1 - build: install locked dependencies with npm ci and export web bundle
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS build

WORKDIR /app

ENV CI=true \
    EXPO_NO_TELEMETRY=1

# Copy dependency manifests first to maximize Docker layer cache reuse
COPY package.json package-lock.json ./

RUN --mount=type=cache,id=circleguard-mobile-npm,target=/root/.npm \
    npm ci --no-audit --no-fund

# Copy application sources and static assets
COPY . .

# Optional build-time defaults (overridden dynamically at runtime via /runtime-config.js)
ARG EXPO_PUBLIC_APP_ENV=dev
ARG EXPO_PUBLIC_API_BASE_URL=http://localhost:8087
ARG EXPO_PUBLIC_GATEWAY_BASE_URL=http://localhost:8087
ARG EXPO_PUBLIC_AUTH_BASE_URL=http://localhost:8180
ARG EXPO_PUBLIC_IDENTITY_BASE_URL=http://localhost:8083
ARG EXPO_PUBLIC_PROMOTION_BASE_URL=http://localhost:8088
ARG EXPO_PUBLIC_FORM_BASE_URL=http://localhost:8086
ARG EXPO_PUBLIC_FILE_BASE_URL=http://localhost:8085
ARG EXPO_PUBLIC_NOTIFICATION_BASE_URL=http://localhost:8082
ARG EXPO_PUBLIC_DASHBOARD_BASE_URL=http://localhost:8084

# Export static web bundle with Metro
RUN npx expo export --platform web \
 && test -f /app/dist/index.html

# -----------------------------------------------------------------------------
# Stage 2 - runtime: unprivileged Nginx serving SPA on port 8080 (non-root)
# -----------------------------------------------------------------------------
FROM ${NGINX_IMAGE} AS runtime

ARG APP_UID=101
ARG APP_GID=101

# Alpine security fixes published after the base image (nginx, zlib, musl, curl...).
# Trivy reports them as HIGH/CRITICAL otherwise. USER goes back to 101 below.
USER root
RUN apk upgrade --no-cache

LABEL org.opencontainers.image.title="circleguard-web-client" \
      org.opencontainers.image.description="CircleGuard Web Client (Expo React Native Web) served by unprivileged Nginx." \
      org.opencontainers.image.vendor="CircleGuard" \
      org.opencontainers.image.source="https://github.com/CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093"

# Copy SPA + healthcheck Nginx configuration
COPY --chown=${APP_UID}:${APP_GID} nginx.conf /etc/nginx/conf.d/default.conf

# Copy runtime environment configuration generator (runs before nginx starts)
COPY --chown=${APP_UID}:${APP_GID} --chmod=0755 \
     docker-entrypoint.d/40-circleguard-runtime-config.sh \
     /docker-entrypoint.d/40-circleguard-runtime-config.sh

# Copy exported static web assets from build stage
COPY --from=build --chown=${APP_UID}:${APP_GID} /app/dist /usr/share/nginx/html

# Runtime environment defaults (override per environment: dev, stage, prod)
ENV APP_ENV="dev" \
    API_BASE_URL="http://localhost:8087" \
    GATEWAY_BASE_URL="http://localhost:8087" \
    AUTH_BASE_URL="http://localhost:8180" \
    IDENTITY_BASE_URL="http://localhost:8083" \
    PROMOTION_BASE_URL="http://localhost:8088" \
    FORM_BASE_URL="http://localhost:8086" \
    FILE_BASE_URL="http://localhost:8085" \
    NOTIFICATION_BASE_URL="http://localhost:8082" \
    DASHBOARD_BASE_URL="http://localhost:8084"

# Explicit non-root execution (UID 101 = nginx in nginxinc/nginx-unprivileged)
USER ${APP_UID}:${APP_GID}

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
