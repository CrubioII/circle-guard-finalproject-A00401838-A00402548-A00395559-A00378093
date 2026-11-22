# Registro de cambios por ambiente (US-28)

Una fila por cada vez que una versión entra o sale de un ambiente: despliegues, promociones, aprobaciones de prod y rollbacks. Las release notes de cada versión explican qué cambió; este registro dice dónde y cuándo se instaló.

Fuentes de cada fila: la descripción y los artefactos del build de Jenkins (`reports/ci/promotion-stage.json`, `prod-approval.json`, `terraform-apply.json`, `rollback-*.txt`), el historial `history.tsv` de `rollback.sh status <env>` y, en Kubernetes, `k8s-deploy.sh status --env <env>`.

Reglas:

- Toda fila de prod lleva el aprobador y el RFC o comentario registrado en la compuerta de US-31.
- Un rollback lleva la versión de origen, la de destino y el motivo.
- Los cambios de infraestructura (Terraform apply) también se registran, con la versión de la aplicación que estaba en el ambiente.

## Versiones publicadas

| Versión | Fecha | Release notes |
| :--- | :--- | :--- |
| 0.1.0 | 2026-11-08 | [RELEASE_NOTES_v0.1.0.md](RELEASE_NOTES_v0.1.0.md) |

## Registro

| Fecha (UTC) | Ambiente | Plataforma | Cambio | Versión | Desde | Aprobó / RFC | Build | Resultado |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |


Todavía no hay filas: se agregan al cerrar cada despliegue o rollback de la Parte 2, empezando por la primera ejecución en los nodos nuevos. Los nodos actuales tras la migración de cuenta AWS son dev `52.15.165.116`, stage `52.14.89.125` y prod `77.113.211.62` (ver `docs/arquitectura/ARQUITECTURA_P1.md`).
