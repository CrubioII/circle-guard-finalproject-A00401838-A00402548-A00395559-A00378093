# Ceremonias del Sprint 2 (US-29)

Equipo SuperPoderosos (Grupo 5). Scrum Master: Juan Camilo Rubio. Sprint 2 = Parte 2 del proyecto, del miércoles 18 al domingo 22 de noviembre de 2026.

Estado del documento: la planning y el seguimiento hasta el sábado 21 están completos. La review, la retrospectiva y el burndown final se llenan el domingo 22 con el export de Jira (secciones marcadas como pendientes).

## 1. Sprint Planning (miércoles 18)

Objetivo del sprint: llevar CircleGuard de Docker Compose en EC2 a Kubernetes con infraestructura en Terraform, con observabilidad, seguridad, patrones de resiliencia y pruebas de carga y DAST, sin perder la entrega continua dev, stage y prod de la Parte 1.

Capacidad: cuatro personas durante cinco días. La velocidad del Sprint 1 fue de 95 SP, así que se comprometieron 100 SP, unos 25 por persona.

El backlog preliminar de la Parte 2 (US-20 a US-29, 76 SP) tenía historias de 8 a 13 SP que mezclaban entregables. En la planning se partieron en 26 historias de 2 a 8 SP, una rama y un PR cada una. El detalle de historias, criterios y reparto está en [`SPRINT2_BACKLOG_Y_REPARTO.md`](SPRINT2_BACKLOG_Y_REPARTO.md).

| Persona | Rol | SP | Historias |
| :--- | :--- | :---: | :--- |
| Juan Pablo Ordoñez | Backend & Cloud Infrastructure | 25 | US-20, US-35, US-36, US-21, US-44 |
| Juan Camilo Rubio | Scrum Master & DevOps Lead | 26 | US-22, US-38, US-39, US-28, US-23, US-29, US-48, US-49 |
| Esteban Cuéllar | QA Automation & Test Lead | 25 | US-40, US-24, US-43, US-27, US-46, US-47 |
| Santiago Castillo | Frontend & Security | 24 | US-26, US-45, US-37, US-41, US-42, US-25 |

Riesgos identificados en la planning:

- El clúster k3s (US-20 / US-35) es el camino crítico: US-21, US-37, US-39, US-43, US-44 y US-45 lo necesitan.
- Cuatro días hasta la entrega. Se decidió escribir código y pruebas en paralelo sin esperar el clúster e integrar cuando esté listo.
- Límite de 8 vCPU en la cuenta AWS, ya usado por las cuatro instancias de la Parte 1.

## 2. Seguimiento diario

| Día | Avance registrado en el repositorio | Impedimentos |
| :--- | :--- | :--- |
| Mié 18 | Planning y reparto (`SPRINT2_BACKLOG_Y_REPARTO.md`) | Ninguno |
| Jue 19 | US-35: módulos `registry`, `storage` y `observability` con sus pruebas y los tres ambientes | Ninguno |
| Vie 20 | PR #27 de US-35 fusionado en main | Migración a una cuenta AWS nueva: las IP de los cuatro nodos cambiaron |
| Sáb 21 | US-20 (módulos `network` y `compute` con k3s) y US-21 (namespaces, middleware y overlays de Kustomize) publicados en sus ramas. Migración de cuenta verificada (IP de los nodos en scripts, Jenkinsfile y documentos; Jenkins, SonarQube y Nexus responden en `18.117.90.15`). US-22, US-38, US-39, US-28 y US-23 implementados con sus pruebas | La app de dev no responde en `52.15.165.116:8080` tras la migración: falta un despliegue en los nodos nuevos. Las IP públicas no son elásticas y cambian si se reinicia una instancia |
| Dom 22 | Pendiente | Pendiente |

## 3. Sprint Review (pendiente, domingo 22)

Llenar con lo demostrado frente a cada entregable:

| Entregable | Historias | SP | Estado | Evidencia |
| :--- | :--- | :---: | :--- | :--- |
| E2.1 IaC con Terraform | US-20, US-35, US-36 | 14 | | |
| E2.2 Kubernetes | US-21, US-37 | 13 | | |
| E2.3 Pipeline incrementado | US-22, US-38, US-39 | 11 | Código y pruebas listos; falta la primera ejecución real en Jenkins | `docs/arquitectura/PIPELINE_PLATAFORMA_US22_US38_US39.md` |
| E2.4 Patrones | US-23, US-40, US-41, US-42 | 13 | US-23 listo | `docs/patrones/PATRONES_EXISTENTES.md` |
| E2.5 Observabilidad | US-24, US-43, US-25, US-44 | 18 | | |
| E2.6 Seguridad | US-26, US-45 | 8 | | |
| E2.7 Pruebas avanzadas | US-27, US-46, US-47 | 10 | | |
| E2.8 Rollback | US-28 | 3 | Código y pruebas listos; falta el rollback ejecutado en stage | `docs/operaciones/ROLLBACK_K8S_US28.md` |
| E2.9 / E2.10 Cierre | US-29, US-48, US-49 | 10 | En curso | este documento, `docs/operaciones/MANUAL_OPERACIONES.md`, `docs/presentacion/GUION_DEMO.md` |

Puntos comprometidos: 100 SP. Puntos completados: pendiente. Cumplimiento: pendiente.

## 4. Retrospectiva (pendiente, domingo 22)

Formato: lo que funcionó, lo que generó fricción y acciones, igual que en el Sprint 1.

Temas ya anotados para la discusión:

- Partir las historias en 2 a 8 SP permitió avanzar en paralelo sin clúster, a cambio de más PR que revisar.
- La migración de cuenta AWS a mitad del sprint obligó a actualizar IP fijas en más de 30 archivos. Acción candidata: IP elásticas o DNS para los nodos, y que los scripts lean las IP de variables o de Terraform outputs.
- Las ramas de US-20 y US-21 se crearon desde un main anterior a US-35; conviene rebasarlas antes de fusionar.

## 5. Burndown y comparación con el Sprint 1 (pendiente)

Exportar de Jira (tablero SuperPoderosos) el burndown del Sprint 2 y llenar:

| Día | Fecha | SP ideales restantes | SP reales restantes |
| :--- | :--- | :---: | :---: |
| 0 | Mié 18 | 100 | 100 |
| 1 | Jue 19 | 80 | |
| 2 | Vie 20 | 60 | |
| 3 | Sáb 21 | 40 | |
| 4 | Dom 22 | 0 | |

| Métrica | Sprint 1 | Sprint 2 |
| :--- | :---: | :---: |
| SP comprometidos | 95 | 100 |
| SP completados | 95 | |
| Velocidad por persona | 23.75 | |
| Historias | ver `SPRINT_0_Y_1_CEREMONIAS.md` | 26 |
