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
| `E2E against dev` | Abre túneles SSH hacia los puertos de dev y ejecuta la suite Playwright de `e2e/`. Publica `reports/e2e/junit.xml` | `deploy/scripts/run-e2e.sh` |
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

## Suite E2E (`e2e/`): contrato para US-17

Es Playwright API testing (`@playwright/test` 1.48.2), sin navegadores. Las URLs se configuran por variables:

`E2E_AUTH_URL`, `E2E_IDENTITY_URL`, `E2E_PROMOTION_URL`, `E2E_FORM_URL`, `E2E_GATEWAY_URL`, `E2E_WEB_URL`. También `E2E_TARGET_ENV`, `E2E_USERNAME`/`E2E_PASSWORD` (por defecto el usuario semilla `staff_guard`) y `E2E_REPORT_DIR`.

| Archivo | Flujo |
|---|---|
| `health.spec.ts` | Readiness `UP` de los 5 servicios, más `/healthz` del web |
| `auth-identity.spec.ts` | Login dual-chain que devuelve un JWT Bearer y un `anonymousId`. Una contraseña incorrecta da 401. El `anonymousId` del login coincide con el de identity, y el mapeo de identity es determinista y sin colisiones |
| `gate-qr.spec.ts` | Generar un QR exige autenticación. Un QR emitido por auth es aceptado por gateway (`GREEN`). **La vigencia real del QR coincide con `expiresIn`**. Una firma alterada da `RED` |
| `web-client.spec.ts` | Se sirve la SPA y `runtime-config.js` contiene las URLs del ambiente |

US-17 agrega sus flujos como nuevos `*.spec.ts` en `e2e/tests/`. El pipeline no cambia: cualquier test que falle bloquea la promoción.

## Defecto encontrado por los E2E: QR que nace caducado

`auth-service/src/main/resources/application.yml` define `qr.expiration: 300`, pero `QrTokenService` interpreta ese valor en **milisegundos**. El QR nacía con `exp == iat`, es decir, caducado, aunque la API anuncia `"expiresIn": "60"`. La validación en gateway fallaba de forma intermitente: a veces pasaba en un reintento.

- **En los despliegues se corrige por configuración.** Los tres `docker-compose.<env>.yml` definen `QR_EXPIRATION=${QR_EXPIRATION_MS:-60000}` (60 s) en auth-service.
- **Pendiente para el equipo de la aplicación:** corregir el valor o la unidad en el `application.yml`, que sigue afectando a `bootRun` local. El test "la vigencia real del QR coincide con `expiresIn`" protege contra una regresión.

## Validación

| Comando | Cubre |
|---|---|
| `./gradlew validateJenkinsMultibranchPipeline` | Casos 15 a 19: plan de entrega continua (solo `main`), `promotionDecision` (promueve o bloquea con su motivo), cableado y orden del Jenkinsfile, scripts y contrato E2E |
| `bash deploy/scripts/test-deploy-scripts.sh` | 31 pruebas sin Docker: SemVer y `latest`, ambientes, `--host`, comandos SSH/SCP (`--dry-run`), contraseña fuera de argumentos y puertos del túnel iguales a los del compose. Se ejecuta en cada PR |
| `bash deploy/scripts/environment.sh deploy\|verify --env dev --version X --local` y `bash deploy/scripts/run-e2e.sh --env dev --local` | Las mismas etapas contra una pila local (`deploy/compose/smoke-up.sh` con `KEEP_UP=1`) |
