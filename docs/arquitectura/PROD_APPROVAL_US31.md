# US-31 — Aprobación manual y despliegue verificado a prod

Cuando un build de `main` deja una versión validada en dev (con E2E) y en stage (US-13), el pipeline **se detiene a esperar la aprobación explícita** de un responsable de release. Solo con una aprobación válida despliega esa misma versión en **prod** y verifica sus healthchecks.

Toda decisión queda registrada: aprobación, rechazo, timeout o abort.

```
… Promote to stage ─► Verify stage health ─► Approve prod release ─► Deploy to prod ─► Verify prod health
                                                   (CA1 + CA2)          solo APPROVED         (CA3)
```

## CA1 — Compuerta manual

La etapa `Approve prod release` corre en `main` y solo si `Verify stage health` terminó en `SUCCESS`. Muestra un `input` con tres campos:

| Campo | Valores | Para qué |
|---|---|---|
| `DECISION` | `RECHAZAR` (por defecto) o `APROBAR` | `APROBAR` despliega. `RECHAZAR` deja prod intacto y **registra quién rechazó** |
| `VERSION` | Solo la versión validada en esta ejecución | Impide promover algo que no pasó dev, E2E y stage |
| `COMMENT` | Justificación o ID de RFC | **Obligatorio para aprobar** (política de cambios de US-18) |

Reglas de la decisión (`multibranchFlow.prodApprovalDecision`, probada en el caso 21):

| Situación | Estado | ¿Despliega? |
|---|---|---|
| Aprueba un usuario listado, con la versión validada y un comentario | `APPROVED` | Sí |
| Rechaza un usuario listado | `REJECTED` | No. El build termina en `SUCCESS` |
| Responde alguien que **no** está en `CG_PROD_APPROVERS`, falta el comentario o la versión no es la validada | `INVALID` | No. Se vuelve a pedir la decisión (máximo 3 intentos) y después el build falla |
| Nadie responde dentro de `CG_PROD_APPROVAL_TIMEOUT_MIN` | `TIMEOUT` | No |
| Alguien presiona *Abort*, o un push nuevo a `main` cancela el build | `ABORTED` | No. El build queda `ABORTED` |
| `CG_PROD_APPROVERS` está vacío | `NOT_CONFIGURED` | No. Ni siquiera se muestra el `input` |

## CA2 — Registro

En `post { always }` se escribe `reports/ci/prod-approval.json`, que queda archivado en el build. Incluye:

- el estado y si se desplegó;
- `approver`, es decir, quién aprobó o rechazó (lo entrega `submitterParameter`);
- la versión, el comentario o RFC y el número de intentos;
- los resultados del despliegue y la verificación, el host de prod, el commit y la URL del build.

El resumen también se agrega a la descripción del build y al estado de GitHub. Por ejemplo: `… | PROD APPROVED por ana (v1.4.0) | despliegue=SUCCESS, health=SUCCESS`.

## CA3 — Verificación visible en Jenkins

`Verify prod health` ejecuta `environment.sh verify --env prod`, que revisa por SSH los 12 contenedores, la versión exacta de cada imagen, el readiness y `/healthz`. El reporte `reports/ci/health-prod.json` se convierte con `deploy/scripts/health-report-to-junit.sh` a `reports/ci/junit/health-prod.xml`, y se publica con `junit`.

Así aparece en la pestaña **Tests** del build como `circleguard.prod.health`, con un caso por contenedor y el motivo de cada fallo. Si la verificación falla, el build falla. El rollback corresponde a US-14.

## Configuración (variables globales de Jenkins)

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `CG_PROD_APPROVERS` | *(vacío)* | **IDs de usuario** de Jenkins separados por comas, por ejemplo `ana,luis`. No se aceptan grupos. Mientras esté vacío, el release a prod se omite |
| `CG_PROD_APPROVAL_TIMEOUT_MIN` | `60` | Minutos que el build espera la decisión |
| `CG_PROD_HOST` | `3.19.74.9` | Nodo prod de US-05 |

Credenciales: las mismas de US-13 (`circleguard-env-ssh` y `nexus-credentials`).

### Importante: Jenkins permite a los administradores aprobar cualquier `input`

El parámetro `submitter` de `input` **no aplica a los usuarios con *Overall/Administer***. Con la estrategia `loggedInUsersCanDoAnything`, que es la habitual cuando no se instala un plugin de permisos, **todo usuario autenticado es administrador**. Por eso hay dos capas de protección:

1. **Pipeline (siempre activa).** `prodApprovalDecision` solo acepta respuestas de usuarios incluidos en `CG_PROD_APPROVERS`. Si responde otro, la respuesta queda `INVALID`, el intento se registra en el log y se vuelve a pedir.
2. **Jenkins (recomendada).** Con `matrix-auth` (o `role-strategy`), los aprobadores tienen `Overall/Read`, `Job/Read` y `Job/Build`, sin `Administer`. En ese caso Jenkins mismo rechaza el envío de un usuario no listado.

### Abort sin autor

El *sandbox* bloquea `FlowInterruptedException.getCauses`, así que un *Abort* se registra **sin usuario**. Hay dos alternativas:

- Usar `RECHAZAR` en lugar de *Abort*, que registra siempre a quien decide.
- Que un administrador apruebe esa firma en *In-process Script Approval*, y a partir de ahí también se registra quién abortó.

Los timeouts se detectan por el tiempo esperado, sin necesitar aprobaciones de *sandbox*.

**Ejecutor ocupado:** mientras espera la decisión, el build ocupa un ejecutor del agente hasta que alguien responde o vence el plazo.

## Validación

| Prueba | Resultado |
|---|---|
| `./gradlew validateJenkinsMultibranchPipeline` | Casos 20 a 22: plan (solo `main`, después de stage), reglas de decisión y cableado del Jenkinsfile. El caso 17 solo admite `--env prod` después de la compuerta |
| `bash deploy/scripts/test-deploy-scripts.sh` | Sección 6: el conversor de salud a JUnit (sano, con fallo, escape XML y nodo sin respuesta) |
| **Jenkins 2.580.2 real** (contenedor desechable, job en *sandbox*, pipeline extraído textualmente de este Jenkinsfile) | `eve` no listada aprueba → `INVALID`, se vuelve a pedir y `ana` aprueba → `APPROVED por ana`. `luis` rechaza → `REJECTED por luis`. Sin comentario → se vuelve a pedir. *Abort* → `ABORTED`. Sin respuesta durante 1 min → `TIMEOUT`. Sin aprobadores → `NOT_CONFIGURED`. Con `matrix-auth`, Jenkins rechaza a `eve` (HTTP 400) y el `input` sigue pendiente |
