# Rollback a la última versión estable (`US-14` / `SCRUM-26`, CA2)

> **Proyecto:** CircleGuard — Ingeniería de Software V (Universidad Icesi)
> **Entregable:** `E1.5` — rollback básico redesplegando una versión anterior.
> **Criterio de rúbrica:** `P1.5` — "rollback demostrado".

## 1. Idea general

Cada ambiente (`dev`, `stage`, `prod`) guarda qué versión SemVer está desplegada y cuál fue la **última versión estable**, es decir, la última que pasó el smoke test / healthcheck después de desplegarse. Si un despliegue falla, el pipeline vuelve a levantar la pila con la versión estable usando las mismas imágenes inmutables del registro (US-11) y los `docker-compose` por ambiente (US-08).

```text
despliegue 1.1.0 ──> mark-deployed 1.1.0 ──> smoke test
                                               │
                         ┌───── pasa ──────────┴────── falla ─────┐
                         ▼                                         ▼
                 mark-stable 1.1.0                  rollback -> 1.0.0 (última estable)
```

## 2. Archivos

| Archivo | Propósito |
| :--- | :--- |
| `infra/scripts/rollback.sh` | Registra versiones y ejecuta el rollback con `docker compose`. |
| `infra/scripts/test-rollback.sh` | Pruebas automatizadas del script con un `docker` simulado. |
| `jenkins/vars/rollbackDeployment.groovy` | Pasos de la Shared Library para el pipeline. |

Estado por ambiente: `$JENKINS_HOME/circleguard-releases/<env>/` (persiste en el volumen de Jenkins, que es quien despliega) o `/var/lib/circleguard/releases/<env>/` fuera de Jenkins.

- `current_version`: versión desplegada actualmente.
- `last_stable_version`: última versión que pasó el smoke test.
- `previous_stable_version`: versión estable anterior a la última.
- `history.tsv`: historial con fecha, evento, versión y enlace al build.

## 3. Cómo se usa

### 3.1. Automático (lo invoca el despliegue de US-13)

```groovy
rollbackDeployment.markDeployed(env: 'stage', version: semver)
try {
    // despliegue + smoke test (deploy/compose/smoke-up.sh)
    rollbackDeployment.markStable(env: 'stage', version: semver)
} catch (err) {
    rollbackDeployment(env: 'stage', host: env.STAGE_HOST)   // vuelve a la última versión estable
    throw err                           // el build queda en FAILURE y se notifica en Discord (NOTIFICACIONES_US14.md)
}
```

Con `host`, el rollback reutiliza el mismo orquestador del despliegue (`deploy/scripts/environment.sh deploy` + `verify` por SSH), así que restaura exactamente igual que un despliegue normal y valida la salud del ambiente.

### 3.2. Manual desde Jenkins (pendiente de integrar)

Cuando se fusione el despliegue de US-13, el `Jenkinsfile` incorporará el parámetro `ROLLBACK_TARGET_VERSION` y una etapa `Rollback` que llame a `rollbackDeployment(env: TARGET_ENV, targetVersion: ROLLBACK_TARGET_VERSION, host: ...)`. Se integra después para no generar conflictos con los cambios de US-13 sobre el mismo `Jenkinsfile`. La etapa solo correrá en `main` y en `prod` pedirá aprobación manual.

### 3.3. Manual por terminal

```bash
./infra/scripts/rollback.sh status stage
./infra/scripts/rollback.sh rollback stage              # última estable
./infra/scripts/rollback.sh rollback stage --to 0.1.0   # versión concreta
./infra/scripts/rollback.sh rollback stage --host <IP>  # en el nodo remoto (SSH, US-13)
DRY_RUN=1 ./infra/scripts/rollback.sh rollback stage    # solo muestra los comandos
```

## 4. Reglas de seguridad

- Solo acepta versiones SemVer (`X.Y.Z` o `X.Y.Z-rc.N`); `latest` se rechaza siempre.
- Después del rollback verifica que todos los servicios queden `healthy` y que las imágenes de CircleGuard corran con la versión restaurada. Si no, termina con código `3` y lo registra en el historial.
- Sin versión estable registrada, se rechaza (código `2`) en lugar de adivinar.

## 5. Pruebas

```bash
bash infra/scripts/test-rollback.sh
```

Cubre: rechazo sin versión estable, restauración tras un despliegue fallido, vuelta a la estable anterior, `--to` explícito, rechazo de `latest` y de versiones no SemVer, pila que no queda saludable, `dev` sin `pull`, ambiente inválido y el modo remoto con `--host` (redespliegue y verificación correctos, y verificación fallida).

## 6. Evidencia pendiente (CA3)

La prueba real de rollback se hará cuando el despliegue de US-13 esté activo: desplegar una versión estable, desplegar una versión con un fallo controlado y capturar el rollback automático y el estado final con `rollback.sh status <env>`.
