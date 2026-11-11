# Notificaciones del pipeline en Discord (`US-14` / `SCRUM-26`, CA1 — subtarea `SCRUM-70`)

> **Proyecto:** CircleGuard — Ingeniería de Software V (Universidad Icesi)
> **Entregable:** `E1.5` — notificaciones de fallos del pipeline.

## 1. Idea general

Cuando termina un build del job `circleguard-monorepo`, Jenkins publica el resultado en el canal de texto `#pipeline` del servidor de Discord **CircleGuard CI**. Así el equipo se entera de un fallo sin tener que entrar a Jenkins, y el mensaje trae todo lo necesario para empezar a revisarlo:

| Dato | De dónde sale |
| :--- | :--- |
| Rama y Pull Request | `multibranchFlow.collectContext()` y `CHANGE_*` del Multibranch (US-30) |
| Commit y mensaje | `git log` del workspace (en un PR, el commit del autor y no el merge de Jenkins) |
| Autor | Autor del PR en GitHub o autor del commit |
| Versión | SemVer calculada por US-12 (`APP_VERSION`) |
| Etapa fallida | Última etapa iniciada (`pipelineTrack.stage`) |
| Detalle | Descripción del build (decisión de promoción de US-13 y de prod de US-31) |
| Log | `BUILD_URL/console` |

```text
build termina ──> post { cleanup } ──> notifyPipeline ──> curl POST webhook ──> #pipeline
                                         │
                                         └─ si falla el envío: advertencia en el log, el build no cambia
```

## 2. Archivos

| Archivo | Propósito |
| :--- | :--- |
| `jenkins/vars/notifyPipeline.groovy` | Paso de la Shared Library: arma el mensaje (embed de Discord), aplica la política y lo envía. |
| `jenkins/vars/notifyPipeline.txt` | Ayuda del paso en Jenkins. |
| `Jenkinsfile` | Registra la etapa en curso en cada etapa y llama al paso en `post { cleanup }`. Parámetro `NOTIFY_DISCORD`. |
| `jenkins/test/validateNotifyPipeline.groovy` | 8 casos de prueba sin Jenkins ni red. |
| `jenkins/test/run-notify-validation.sh` | Ejecuta las pruebas con Groovy (local o descargado). |

## 3. Cuándo se notifica

| Resultado | ¿Notifica? |
| :--- | :--- |
| `FAILURE`, `ABORTED`, `UNSTABLE` | Siempre (cualquier rama o PR). |
| `SUCCESS` después de un build fallido | Siempre, como **RECUPERADO**. |
| `SUCCESS` en `main` | Sí (es una entrega a dev/stage/prod). |
| `SUCCESS` en una rama o PR sin fallo previo | No, para no llenar el canal de ruido. |

El parámetro `NOTIFY_DISCORD=false` desactiva la notificación en una ejecución manual.

## 4. Configuración (una sola vez)

1. En Discord: servidor **CircleGuard CI** → canal `#pipeline` → *Editar canal* → *Integraciones* → *Webhooks* → *Nuevo webhook* (`Jenkins`) → *Copiar URL*.
2. En Jenkins: *Manage Jenkins* → *Credentials* → *System* → *Global credentials* → *Add Credentials*:
   - **Kind:** `Secret text`
   - **Secret:** la URL del webhook
   - **ID:** `discord-webhook`

La URL del webhook es un secreto: quien la tenga puede publicar en el canal. Por eso solo vive en el almacén de credenciales de Jenkins; el `Jenkinsfile` la inyecta con `withCredentials` y `curl` la lee desde una variable de entorno, así que no aparece ni en el repositorio ni en el log (Jenkins además la enmascara con `****`).

## 5. Decisiones

- **`post { cleanup }`:** corre al final de todo, cuando el resultado y la descripción del build ya son definitivos, y un error ahí no cambia el resultado.
- **`load` desde el workspace:** la Shared Library global usa la versión de `main` (`defaultVersion: "main"` en `jenkins/ci/jenkins.yaml`). Cargar el paso desde el workspace hace que cada rama o PR pruebe su propia versión, y evita que un PR falle por un paso que todavía no está en `main`.
- **Etapa fallida:** Declarative no expone en el `post` global qué etapa falló sin aprobaciones de sandbox. Por eso cada etapa guarda su nombre (`env.STAGE_NAME`) al iniciar, y al fallar el build la última registrada es la que falló.
- **Sin menciones:** `allowed_mentions: { parse: [] }` evita que un mensaje de commit con `@everyone` notifique a todo el servidor.

## 6. Pruebas

```bash
bash jenkins/test/run-notify-validation.sh
# o, sin instalar Groovy:
./gradlew validateJenkinsNotifications
```

Cubre: fallo en `main` con todos los datos, fallo en un PR (enlace y rama destino), la política de la sección 3, el mensaje de recuperación, la credencial ausente y Discord con error (solo advertencias), el modo `dry-run`, el commit real tras el merge de un PR y el recorte a los límites de Discord y que las firmas de los métodos sean compatibles con el intérprete CPS de Jenkins (sin parámetros primitivos ni por defecto, que fallan al cargar el paso con `load`). También comprueba que la URL del webhook nunca se interpole en el comando ni aparezca en el log.

## 7. Evidencia

- Mensaje de un build fallido en `#pipeline` (rama, commit, autor, versión, etapa y log).
- Mensaje de recuperación cuando el siguiente build pasa.
- La notificación del fallo controlado con rollback (CA3, subtarea `SCRUM-72`) se captura cuando el despliegue tenga la credencial `circleguard-env-ssh`.
