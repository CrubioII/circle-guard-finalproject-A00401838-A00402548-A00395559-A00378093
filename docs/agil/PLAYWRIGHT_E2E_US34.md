# US-34 — Framework Playwright y ejecución E2E integrada a Jenkins

| Campo | Valor |
| :--- | :--- |
| Historia | US-34 (4 SP) |
| Rol | Ingeniero DevOps |
| Objetivo | Configurar Playwright para ejecución headless y reportes en Jenkins, de modo que los flujos E2E de US-17 se repitan y se revisen desde el pipeline. |
| Relación | US-34 entrega el **framework** (configuración, fixtures, reportes, etapa CI). Los **flujos de negocio** (inicio de sesión, cuestionario de salud, validación de acceso) los implementa **US-17** en `e2e/tests/flows/`. |

## 1. Estructura

```text
e2e/
├── package.json             # @playwright/test fijado (1.63.0) + scripts npm
├── package-lock.json        # npm ci reproducible en Jenkins
├── playwright.config.ts     # BASE_URL, headless, reporters HTML + JUnit, webServer local
├── scripts/serve-dist.mjs   # servidor estático sin dependencias para mobile/dist (replica nginx.conf)
├── support/fixtures.ts      # fixtures compartidos: session, api (mocks), consoleErrors
└── tests/
    ├── smoke/app-shell.spec.ts   # @smoke: el cliente arranca y redirige a /login
    └── flows/README.md           # convenciones y ubicación de los flujos @us17 (US-17)
```

La suite vive fuera de `mobile/` para no mezclar dependencias de Jest/Expo con Playwright. Un cambio en `e2e/` activa la etapa web del pipeline igual que un cambio en `mobile/` (`detectChangedServices`, caso 4b de `validateSharedLibrary.groovy`).

## 2. Criterios de aceptación

### CA1 — `BASE_URL` parametrizable y reportes HTML + JUnit

`playwright.config.ts` resuelve la URL así:

| Variable | Efecto |
| :--- | :--- |
| `BASE_URL` | URL del cliente web a probar (p. ej. `http://<host>:8081` del ambiente stage). Si está vacía, Playwright levanta `scripts/serve-dist.mjs` sobre `mobile/dist` en `http://127.0.0.1:${E2E_PORT:-4173}` y espera a `/healthz`. |
| `E2E_WEB_DIST` | Carpeta del export web alternativa (por defecto `../mobile/dist`). |
| `E2E_MOCK_API` | `true` (por defecto) permite que los flujos simulen `/api/v1/**` con el fixture `api`; Jenkins lo pone en `false` cuando se pasa `E2E_BASE_URL` para ir contra los servicios reales. |
| `E2E_RETRIES` | Reintentos por spec (por defecto `0`, ver CA3). |
| `E2E_STRICT_HYDRATION` | `1` también reporta los avisos de hidratación de React (#418) que hoy produce el export estático de Expo. |

Reportes generados en cada ejecución:

- HTML navegable: `e2e/reports/html/index.html` (con trazas, capturas y video de los specs fallidos).
- JUnit: `e2e/reports/junit/results.xml`.

### CA2 — Jenkins ejecuta Playwright headless y publica los reportes

Etapa `E2E Playwright` del `Jenkinsfile`, justo después de `Compile & Test Web`:

1. Se ejecuta cuando `plan.runMobileBuild == true` (cambios en `mobile/` o `e2e/`, o `FORCE_FULL_BUILD`) o cuando se define el parámetro `E2E_BASE_URL`.
2. Sin `E2E_BASE_URL`: `npx expo export --platform web` en `mobile/` y la suite corre contra ese export servido en el agente (pipeline autocontenido, sin backend).
3. `npm ci` + `npx playwright install chromium` en `e2e/`. Las librerías de sistema de Chromium ya están en la imagen `infra/bootstrap/jenkins/Dockerfile` (US-04) y `PLAYWRIGHT_BROWSERS_PATH` apunta a `/var/jenkins_home/.cache/ms-playwright`, así que el navegador se descarga una sola vez.
4. `npx playwright test` con `CI=true` → `headless: true` (solo `HEADED=1` fuera de CI abre el navegador).
5. `post { always { ... } }` de la etapa:
   - `junit 'e2e/reports/junit/*.xml'` → resultados y tendencia en la vista del build.
   - `publishHTML` → enlace **Playwright E2E** en el menú lateral del job/build (plugin `htmlpublisher`, añadido a `plugins.txt`).
   - `archiveArtifacts 'e2e/reports/**,e2e/test-results/**'` → reporte, trazas, capturas y videos descargables.

El reporte HTML de Playwright usa JavaScript; `docker-compose.ci.yml` ya arranca Jenkins con `-Dhudson.model.DirectoryBrowserSupport.CSP=` para que se renderice dentro de Jenkins.

### CA3 — La ejecución falla si falla cualquiera de los flujos de US-17

- `sh 'npx playwright test'` no usa `|| true` ni `catchError`: un código de salida distinto de 0 marca la etapa y el build como `FAILURE` y el `post` global publica `FAILURE` en GitHub.
- Se ejecuta **toda** la carpeta `tests/` (sin `--grep`), por lo que cualquier spec nuevo de `tests/flows/` entra automáticamente al gate.
- `forbidOnly` está activo en CI (un `test.only` olvidado rompe el build) y `retries` es `0` por defecto, así que un flujo inestable también falla.
- Verificado localmente: con un spec `@us17` que falla a propósito, `npx playwright test` terminó con `EXIT=1` y el JUnit registró el fallo.

## 3. Ejecución local

```bash
# 1) Export web del cliente (una vez por cambio en mobile/)
cd mobile && npm ci && npx expo export --platform web && cd ..

# 2) Suite E2E headless contra el export local
cd e2e && npm ci && npx playwright install chromium
npm test                       # todo
npm run test:smoke             # solo @smoke
npm run test:flows             # solo flujos @us17
npm run report                 # abre reports/html

# 3) Contra un ambiente desplegado (CA1)
BASE_URL=http://localhost:8081 E2E_MOCK_API=false npm test
```

## 4. Estado de los flujos de US-17

| Flujo (E1.6) | Spec | Estado |
| :--- | :--- | :--- |
| Inicio de sesión | `e2e/tests/flows/login.spec.ts` | Pendiente (US-17) |
| Cuestionario de salud | `e2e/tests/flows/health-questionnaire.spec.ts` | Pendiente (US-17) |
| Validación de acceso | `e2e/tests/flows/access-validation.spec.ts` | Pendiente (US-17) |

`e2e/tests/flows/README.md` incluye un ejemplo de inicio de sesión con la API simulada, verificado contra el export actual.

## 5. Observación conocida

El export estático de Expo genera un aviso de hidratación de React (`Minified React error #418`) al cargar `/login`. No bloquea la interfaz, por lo que el fixture `consoleErrors` lo ignora por defecto; se puede volver estricto con `E2E_STRICT_HYDRATION=1` cuando se corrija en `mobile/`.
