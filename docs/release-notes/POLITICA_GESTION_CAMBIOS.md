# Politica de gestion de cambios y liberaciones (US-18 / SCRUM-30)

Esta politica define las directrices, roles y flujos de aprobacion para la promocion de cambios tecnicos hacia los ambientes de CircleGuard (dev, stage y prod). Su objetivo es mantener trazabilidad y control de riesgos mediante versionado semantico y revision sistematica.

## 1. Clasificacion de tipos de cambio

Los cambios se agrupan en tres categorias operativas segun su nivel de impacto y urgencia:

| Tipo de cambio | Criterios tecnicos | Impacto y riesgo | Flujo de aprobacion | Ventana de aplicacion |
| :--- | :--- | :--- | :--- | :--- |
| **Estandar** | Modificaciones preaprobadas de bajo riesgo, sin cambios en APIs ni esquemas de datos: actualizaciones de documentacion, tareas de mantenimiento rutinario o ajustes de configuracion no criticos. | Riesgo bajo. No afecta contratos entre servicios ni disponibilidad de usuarios. | Aprobacion automatica mediante paso exitoso del pipeline de CI (pruebas unitarias y control de calidad). | Continua durante horas laborales. |
| **Normal** | Nuevas funcionalidades, mejoras de rendimiento o refactorizaciones estructurales (`feat`, `perf`, `refactor`) promovidas mediante ramas de desarrollo y Pull Requests hacia `main`. | Riesgo moderado. Requiere despliegue secuencial dev -> stage -> prod y verificacion de pruebas de integracion y E2E. | Requiere revision por pares (Peer Review) de al menos un ingeniero del equipo y aprobacion manual en Jenkins (`stage` -> `prod`). | Despliegues planificados segun el ciclo del sprint. |
| **Emergencia / Hotfix** | Correccion de fallos criticos detectados en produccion que comprometen la seguridad, la persistencia de datos o la continuidad del servicio (`hotfix/*`). | Riesgo alto por criticidad temporal. Permite flujo abreviado pero exige registro posterior de RFC y plan de rollback inmediato. | Aprobacion inmediata del Tech Lead o DevOps Lead. Aprobacion manual requerida en Jenkins para el paso a produccion. | Inmediata tras verificacion en ambiente de stage. |

## 2. Matriz de responsabilidades y aprobadores

| Rol | Cambio Estandar | Cambio Normal | Cambio de Emergencia |
| :--- | :---: | :---: | :---: |
| Ingeniero de software (Desarrollador) | Ejecuta | Propone (Crea RFC / PR) | Ejecuta correccion |
| Par revisor (Peer Reviewer) | Opcional | Aprueba PR en GitHub | Aprueba revision inicial |
| DevOps / Platform Lead | Audita | Valida pipeline y aprueba pase a prod | Aprueba despliegue a prod |
| Tech Lead / Release Manager | Notificado | Notificado | Autoriza despliegue de emergencia |

## 3. Esquema de versionado semantico (SemVer 2.0.0)

Cada integracion en la rama `main` calcula la siguiente version analizando los mensajes de commit desde el ultimo tag:

- **MAJOR (`X.0.0`):** Cambios que rompen compatibilidad hacia atras (`BREAKING CHANGE:` o pie con `!:`). Exigen RFC detallado con plan de migracion de esquemas y ventana de mantenimiento acordada.
- **MINOR (`0.X.0` o `X.Y.0`):** Nuevas funcionalidades compatibles hacia atras (`feat:`). Se despliegan en ciclos regulares de entrega continua.
- **PATCH (`0.0.X` o `X.Y.Z`):** Correcciones de defectos (`fix:`), mejoras de rendimiento (`perf:`) o refactorizaciones internas sin alteracion funcional (`refactor:`).

## 4. Requisitos para la promocion a produccion

Ningun artefacto alcanza el ambiente de produccion sin satisfacer los siguientes controles:

1. Pruebas unitarias ejecutadas con cobertura minima del 60% en servicios nucleo.
2. Analisis de calidad estatica en SonarQube sin vulnerabilidades ni errores bloqueantes.
3. Despliegue previo exitoso en los ambientes aislados de `dev` y `stage`.
4. Pruebas E2E automatizadas ejecutadas satisfactoriamente en `stage`.
5. Autorizacion expresa registrada en la etapa de aprobacion manual de Jenkins.
6. Plan de rollback documentado y verificado.
