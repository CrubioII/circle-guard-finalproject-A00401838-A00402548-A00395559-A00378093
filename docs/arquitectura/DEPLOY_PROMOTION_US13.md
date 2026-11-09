# US-13 — Despliegue automático a dev y promoción a stage tras E2E

Toda ejecución del pipeline en `main` que publica imágenes despliega esa misma versión SemVer en **dev**, verifica sus healthchecks y ejecuta los flujos **E2E** contra dev. **Solo si todo pasa**, la misma versión se promueve a **stage**.

- Los Pull Requests y las ramas `feature/*` nunca despliegan (regla de US-30).
- La aprobación manual hacia prod es US-31.

## Flujo en el Jenkinsfile

```
Calculate SemVer ─► Compile & Test ─► Validate Compose ─► Publish Images to Nexus ─► Generate Release Notes & Tag
                                                                                                 │
   ┌─────────────────────────────────────────────────────────────────────────────────────────────┘
   ▼
Deploy to dev ─► Verify dev health ─► E2E against dev ─► Promote to stage ─► Verify stage health
   (CA1)             (CA1)                (CA2)            (CA2 + CA3)
```

| Etapa | Qué hace | Script |
|---|---|---|
| `Deploy to dev` | Copia por SCP `deploy/compose/docker-compose.dev.yml` y los scripts a `/opt/circleguard/dev/compose/stack/`. Luego, por SSH: `docker login` (contraseña por stdin), `pull` y `up -d --wait` con `IMAGE_TAG=<versión US-12>`. Persiste `IMAGE_TAG` en el `.env` y registra `DEPLOYED_VERSION` | `deploy/scripts/environment.sh deploy` → `deploy-env.sh` |
| `Verify dev health` | Por SSH en el nodo: los 12 contenedores deben estar `healthy`, las 6 imágenes propias deben ejecutar exactamente `…/circleguard/<svc>:<versión>`, y cada servicio debe responder `/actuator/health/readiness` = `UP` y el web `/healthz`. Guarda `reports/ci/health-dev.json` | `environment.sh verify` → `verify-env-health.sh` |
| `E2E against dev` | Abre túneles SSH hacia dev y ejecuta contra los **servicios reales** los flujos de US-17 (`@us17`, `@smoke`) y los contratos `@deployed`. Publica `e2e/reports/dev/` (JUnit y HTML) | `deploy/scripts/run-e2e.sh` |
| `Promote to stage` | `multibranchFlow.promotionDecision(...)` exige `SUCCESS` en las tres compuertas anteriores y despliega **la misma versión** en stage | `environment.sh deploy --env stage` |
| `Verify stage health` | La misma verificación de salud, ahora en stage. Guarda `reports/ci/health-stage.json` | `environment.sh verify --env stage` |

La versión desplegada es siempre `APP_VERSION`, la de US-12. `requireReleaseVersion` hace fallar el build si no existe: nunca se despliega un valor por defecto.

## CA3 — Detención y registro

- Cada etapa marca su compuerta en `FAILURE` al empezar y en `SUCCESS` solo al terminar bien. Si una falla, Jenkins omite las siguientes, así que **stage no recibe la versión**.
- En `post { always }` (que corre siempre, también tras un fallo) se escribe `reports/ci/promotion-stage.json`. Contiene el estado (`PROMOTED` o `BLOCKED`), la versión, el detalle de cada compuerta, la primera que bloqueó y el motivo, y los hosts, el commit y la URL del build.
- La misma decisión queda en la **descripción del build** y en el **estado de GitHub** del commit. Por ejemplo: `BLOCKED: Promoción a stage detenida: pruebas E2E contra dev = FAILURE (versión 1.4.0).`
- Jenkins archiva `reports/**` y publica los resultados JUnit de los E2E.

## Por qué SSH y túneles

Los security groups de US-05 solo abren los puertos 22, 8080, 8180 y 8087. Por eso:

- La **verificación de salud** se ejecuta dentro del nodo, con `docker compose ps` y `exec`, y no depende de puertos abiertos.
- Los **E2E** se conectan por túneles `ssh -L` (puertos locales 28xxx hacia `127.0.0.1:<puerto>` del nodo). No hace falta abrir más puertos a Internet.

## Credenciales y configuración de Jenkins (una sola vez)

| Elemento | Tipo | Uso |
|---|---|---|
| `circleguard-env-ssh` | *SSH Username with private key*. Usuario `ec2-user`, llave de los nodos de US-05 (`proyectoIngeClave.pem`) | SCP, SSH y túneles hacia dev y stage |
| `nexus-credentials` | *Username with password* (ya existe por US-11) | Publicar imágenes y descargarlas en los nodos (`docker login --password-stdin`) |
| `openssh-client` en la imagen de Jenkins | Agregado en `infra/bootstrap/jenkins/Dockerfile` | **Reconstruir Jenkins**: `docker compose -f docker-compose.ci.yml --env-file infra/bootstrap/.env.ci up -d --build` (el volumen `jenkins_home` se conserva) |
| `CG_DEV_HOST`, `CG_STAGE_HOST` y `CG_REGISTRY_URL` (opcionales) | Variables globales de Jenkins | Sobrescriben los valores por defecto `52.15.213.209`, `3.17.163.44` y `52.14.6.11:5000` sin tocar el repositorio |

Requisitos en los nodos (ya los cumple US-05):

- Existe `/opt/circleguard/<env>/.env`.
- `ec2-user` pertenece al grupo `docker`.
- `daemon.json` tiene el registro como inseguro.
- El puerto 22 es accesible desde Jenkins (`3.145.182.10`).

La contraseña del registro nunca va en argumentos ni en disco: viaja por stdin de SSH hasta `docker login --password-stdin`. `test-deploy-scripts.sh` lo verifica.

## Suite E2E (`e2e/`): qué corre contra dev

El framework es el de US-34 (Playwright, `e2e/playwright.config.ts`) y los flujos de negocio son los de US-17. El pipeline los ejecuta **dos veces**, con propósitos distintos:

| Etapa | Cuándo | Contra qué | Qué corre |
|---|---|---|---|
| `E2E Playwright` (US-34) | Antes de publicar, si cambia `mobile/` o `e2e/` | `mobile/dist` servido en el agente, con **APIs simuladas** (`E2E_MOCK_API=true`) | Proyecto `chromium`: flujos `@us17` y smoke `@smoke` |
| `E2E against dev` (US-13) | Después de desplegar en dev, en cada build de `main` | **Servicios reales de dev** a través de túneles SSH (`E2E_MOCK_API=false`) | Proyecto `chromium` (`@us17` y `@smoke`, ahora contra el backend real) más el proyecto `deployed-api` (`tests/deployed/`, `@deployed`) |

En modo real, los flujos de US-17 que dependen de respuestas simuladas se omiten (`test.skip(!mockApiEnabled)`); así lo decidió US-17. Sus contrapartes reales las cubren los contratos `@deployed`:

| `tests/deployed/` | Contrato contra el backend real |
|---|---|
| `health.spec.ts` | Readiness `UP` de los 5 servicios, más `/healthz` del web |
| `auth-identity.spec.ts` | Login dual-chain que devuelve un JWT Bearer y un `anonymousId`. Una contraseña incorrecta da 401. El `anonymousId` coincide con el de identity, y el mapeo es determinista y sin colisiones |
| `gate-qr.spec.ts` | Generar un QR exige autenticación. Un QR real es aceptado por gateway (`GREEN`). **La vigencia real del QR coincide con `expiresIn`**. Una firma alterada da `RED` |
| `web-client.spec.ts` | Se sirve la SPA y el `runtime-config.js` real contiene las URLs del ambiente |

Cómo llega el navegador a dev (`deploy/scripts/run-e2e.sh`):

- **El cliente web se sirve por un túnel en `http://localhost:8081`.** El CORS de auth-service solo permite los orígenes `localhost:8080` y `localhost:8081`, y el 8080 del agente lo ocupa Jenkins. El puerto se cambia con `E2E_WEB_LOCAL_PORT`, pero debe seguir siendo un origen permitido.
- **Los servicios se alcanzan por túneles en `127.0.0.1:28xxx`.** Con `E2E_RUNTIME_CONFIG_FROM_ENV=1`, el fixture `runtimeConfigFromEnv` de `support/fixtures.ts` reescribe `/runtime-config.js` para que el navegador use esos túneles, sin depender del `PUBLIC_HOST` del nodo. El contenido real de ese archivo lo valida `deployed/web-client.spec.ts`.
- **Los reportes de esta corrida van a `e2e/reports/dev/`** (JUnit y HTML *Playwright E2E (dev)*) y no se mezclan con los de la etapa previa al despliegue.

Para agregar un flujo: los de negocio van en `tests/flows/` (convenciones de US-17) y los contratos que solo tienen sentido contra un despliegue real van en `tests/deployed/`. El pipeline no cambia, y cualquier test que falle bloquea la promoción.

## Defecto que detectaron los E2E: QR que nacía caducado

`qr.expiration: 300` se interpretaba en **milisegundos**, así que el QR nacía con `exp == iat` aunque la API anuncia `"expiresIn": "60"`. La validación en gateway fallaba de forma intermitente. `main` lo corrigió en el código (`e89bb5f`, `qr.expiration: 60000`). El contrato "la vigencia real del QR coincide con `expiresIn`" protege contra una regresión.

## Validación

| Comando | Cubre |
|---|---|
| `./gradlew validateJenkinsMultibranchPipeline` | Casos 15 a 19: plan de entrega continua (solo `main`), `promotionDecision` (promueve o bloquea con su motivo), cableado y orden del Jenkinsfile, scripts y contrato E2E |
| `bash deploy/scripts/test-deploy-scripts.sh` | 31 pruebas sin Docker: SemVer y `latest`, ambientes, `--host`, comandos SSH/SCP (`--dry-run`), contraseña fuera de argumentos y puertos del túnel iguales a los del compose. Se ejecuta en cada PR |
| `bash deploy/scripts/environment.sh deploy\|verify --env dev --version X --local` y `bash deploy/scripts/run-e2e.sh --env dev --local` | Las mismas etapas contra una pila local (`deploy/compose/smoke-up.sh` con `KEEP_UP=1`) |
