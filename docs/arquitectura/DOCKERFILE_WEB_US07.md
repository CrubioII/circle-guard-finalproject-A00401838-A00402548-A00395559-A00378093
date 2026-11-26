# Contenedorización Multi-stage Segura del Cliente Web (US-07)

## Trazabilidad con Jira
- Historia de usuario: `US-07` (`SCRUM-19`, 3 SP), Creación de Dockerfile multi-stage seguro (no-root) para el cliente web (`mobile/`).
- Épica asociada: `EPIC-03` (`SCRUM-10`, Entregable `E1.3`).
- Subtareas:
  - `SCRUM-49` (1 SP): Escribir `mobile/Dockerfile` multi-stage con `expo export` y Nginx no-root.
  - `SCRUM-48` (1 SP): Configurar `nginx.conf` para soporte de rutas SPA y healthcheck HTTP.
  - `SCRUM-51` (1 SP): Probar la construcción y navegación del contenedor web conectándose a los servicios backend.

---

## 1. Arquitectura de la Imagen Multi-stage (`mobile/Dockerfile`)

El cliente web de CircleGuard (Expo / React Native Web) se empaqueta mediante [`mobile/Dockerfile`](../../mobile/Dockerfile) en dos etapas aisladas:

1. Etapa `build` (`node:20-alpine`):
   - Copia primero [`mobile/package.json`](../../mobile/package.json) y [`mobile/package-lock.json`](../../mobile/package-lock.json) e instala dependencias bloqueadas con `npm ci --no-audit --no-fund` empleando caché BuildKit (`--mount=type=cache`).
   - Copia el código fuente filtrado por [`mobile/.dockerignore`](../../mobile/.dockerignore) (excluyendo `node_modules/`, `dist/`, `.expo/`, llaves y archivos `.env*`).
   - Ejecuta `npx expo export --platform web` y valida la existencia de `/app/dist/index.html`.
2. Etapa `runtime` (`nginxinc/nginx-unprivileged:1.31.7-alpine3.24`):
   - Corre bajo el usuario sin privilegios `101:101` (`nginx`), nunca como `root`.
   - Expone el puerto no privilegiado `8080/tcp`.
   - Incorpora [`mobile/nginx.conf`](../../mobile/nginx.conf) en `/etc/nginx/conf.d/default.conf`, el generador de configuración dinámica [`mobile/docker-entrypoint.d/40-circleguard-runtime-config.sh`](../../mobile/docker-entrypoint.d/40-circleguard-runtime-config.sh) en `/docker-entrypoint.d/` y los artefactos estáticos de `/app/dist` en `/usr/share/nginx/html`.
   - Define `HEALTHCHECK` HTTP contra `http://127.0.0.1:8080/healthz`.

---

## 2. Ruteo SPA, Seguridad y Configuración Dinámica por Ambiente

### Ruteo SPA y Healthcheck (`mobile/nginx.conf`)
- `GET /healthz`: responde `HTTP 200 OK` con `{"status":"UP","service":"circleguard-web"}` sin generar ruido en el log de acceso.
- `GET /_expo/static/*`: sirve bundles JS y CSS con encabezado `Cache-Control: public, max-age=31536000, immutable`.
- `GET /runtime-config.js`: sirve `/tmp/circleguard-runtime-config.js` con `Cache-Control: no-store, no-cache, must-revalidate` para reflejar de inmediato las variables de entorno del contenedor.
- `location /`: aplica `try_files $uri $uri.html $uri/ /index.html;` para resolver tanto las rutas estáticas exportadas por Expo Router (`/login`, `/questionnaire`, `/visitor`, `/admin`) como rutas profundas de navegación SPA.
- Encabezados de endurecimiento: `server_tokens off`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` y `Referrer-Policy: strict-origin-when-cross-origin`.

### Configuración Dinámica para `dev`, `stage` y `prod` (`CA3`)
Para promover una única imagen inmutable entre los ambientes `dev`, `stage` y `prod`:
1. Al arrancar el contenedor, `/docker-entrypoint.sh` ejecuta [`40-circleguard-runtime-config.sh`](../../mobile/docker-entrypoint.d/40-circleguard-runtime-config.sh) con el usuario `101:101` y escribe `/tmp/circleguard-runtime-config.js` a partir de las variables de entorno del contenedor (`APP_ENV`, `API_BASE_URL`, `GATEWAY_BASE_URL`, `AUTH_BASE_URL`, `IDENTITY_BASE_URL`, `PROMOTION_BASE_URL`, `FORM_BASE_URL`, `FILE_BASE_URL`, `NOTIFICATION_BASE_URL`, `DASHBOARD_BASE_URL`).
2. [`mobile/app/+html.tsx`](../../mobile/app/+html.tsx) carga `<script src="/runtime-config.js" />` en el `<head>`.
3. [`mobile/constants/Config.ts`](../../mobile/constants/Config.ts) resuelve cada URL priorizando `globalThis.__CIRCLEGUARD_CONFIG__`, luego `process.env.EXPO_PUBLIC_*` y por último los valores locales por defecto.

---

## 3. Verificación Reproducible (`SCRUM-51`)

Ejecutar la suite automatizada de construcción, seguridad no-root, healthcheck, ruteo SPA e inyección de variables por ambiente:

```bash
./mobile/scripts/verify-web-container.sh
```

Ejecutar las pruebas unitarias de Jest del cliente web:

```bash
cd mobile && npm run test -- --ci --watchAll=false
```
