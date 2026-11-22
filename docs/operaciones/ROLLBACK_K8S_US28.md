# Rollback en Kubernetes y registro de cambios (US-28)

Épica EPIC-16 (change management y rollback, entregable E2.8). Responsable: Juan Camilo Rubio.

El rollback de la Parte 1 ([`ROLLBACK_US14.md`](ROLLBACK_US14.md)) redespliega con Docker Compose la última versión estable. US-28 le agrega el modo Kubernetes y una etapa de Jenkins para pedirlo sin entrar a una terminal.

## Cómo funciona

| Situación | Qué pasa |
| :--- | :--- |
| Un despliegue k8s no queda listo | `verifyK8sOrRollback` en el Jenkinsfile ve fallar `k8s-deploy.sh verify` (rollout status), corre `rollback.sh rollback <env> --platform k8s` y falla la etapa. Discord avisa (US-14) |
| Rollback manual desde Jenkins | Parámetros `ROLLBACK_ENV` y `ROLLBACK_TARGET_VERSION` en un build de main. La etapa `Manual Rollback` corre sola: sin build, sin Terraform y sin despliegue nuevo. En prod pide aprobación de `CG_PROD_APPROVERS` |
| Rollback por terminal | `infra/scripts/rollback.sh rollback <env> --platform k8s [--to X.Y.Z]` con `KUBECONFIG` del ambiente |

En Kubernetes, sin `--to` se usa `kubectl rollout undo` sobre los Deployments con `app.kubernetes.io/part-of=circleguard`. El historial de revisiones lo guarda el clúster, así que no depende del estado local de Jenkins. Con `--to X.Y.Z` se redespliega esa etiqueta con `k8s-deploy.sh deploy` y se espera el rollout. En Compose, sin `--to` se restaura la última versión estable registrada; el Jenkinsfile marca como estable cada versión que pasa la verificación de un ambiente (`rollback.sh mark-stable`).

La etapa `Manual Rollback` deja `reports/ci/rollback-before-<env>.txt` y `rollback-after-<env>.txt` con el estado del ambiente antes y después (versión, imágenes, revisiones). Esos dos archivos y la consola del build son la evidencia del CA2.

## Criterios de aceptación

| Criterio | Estado |
| :--- | :--- |
| CA1: `rollback.sh` o una etapa de Jenkins soporta `kubectl rollout undo` o redeploy de la etiqueta anterior | Hecho: `rollback.sh --platform k8s`, `k8s-deploy.sh rollback` y la etapa `Manual Rollback`. Pruebas: casos 11 a 13 de `infra/scripts/test-rollback.sh` y caso 7b de `jenkins/test/validatePlatformFlow.groovy` |
| CA2: rollback ejecutado en stage o prod con capturas antes y después | Pendiente de ejecución: necesita el clúster de stage con los servicios desplegados (US-21 / US-37). Pasos abajo |
| CA3: release notes por versión y registro de cambios por ambiente | Release notes automáticas por versión (US-18, etapa `Generate Release Notes & Tag`). Registro en [`REGISTRO_CAMBIOS_POR_AMBIENTE.md`](../release-notes/REGISTRO_CAMBIOS_POR_AMBIENTE.md) |

## Guion para la evidencia del CA2

1. Con dos versiones desplegadas en stage (por ejemplo `1.1.0` y luego `1.2.0`), correr `k8s-deploy.sh status --env stage` y capturar la versión y el historial de revisiones.
2. En Jenkins, `Build with Parameters` sobre main: `ROLLBACK_ENV=stage`, `ROLLBACK_TARGET_VERSION` vacío, `DEPLOY_PLATFORM=k8s`.
3. Capturar la consola del build y los artefactos `rollback-before-stage.txt` y `rollback-after-stage.txt`.
4. Comprobar que `kubectl -n circleguard-stage get deploy -o wide` muestra las imágenes `:1.1.0` y que los healthchecks responden.
5. Agregar la fila al registro de cambios con el enlace al build.
