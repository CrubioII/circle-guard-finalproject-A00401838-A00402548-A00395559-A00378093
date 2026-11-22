# Sustentación de la Parte 2: estructura y guion de demo (US-49)

Duración objetivo: 25 minutos (rango permitido de 20 a 30), más preguntas. Cada integrante presenta lo que construyó (CA3).

## Estructura

| Min | Bloque | Presenta | Contenido |
| :--- | :--- | :--- | :--- |
| 0 a 3 | Introduction (in English) | Juan Camilo | Qué es CircleGuard, qué se entregó en la Parte 1, qué agrega la Parte 2. Base: `docs/informe/EXECUTIVE_SUMMARY.md` |
| 3 a 7 | Infraestructura y Kubernetes | Juan Pablo | Módulos de Terraform, backend con bloqueo, tres ambientes, diagrama. Namespaces, middleware y overlays |
| 7 a 12 | Pipeline | Juan Camilo | Demo 1: un commit llega a prod con aprobación (ver abajo). Trivy, Terraform plan/apply y rollback |
| 12 a 17 | Patrones y seguridad | Santiago y Esteban | Catálogo de patrones existentes (US-23), Circuit Breaker, Feature Toggle, tercer patrón. Secretos, RBAC y TLS |
| 17 a 22 | Observabilidad y pruebas | Esteban y Santiago | Demo 2: falla provocada que dispara alerta y traza. Resultados de Locust y ZAP |
| 22 a 25 | Cierre | Juan Camilo | Métricas del sprint frente al Sprint 1, costos, lo que falta y lo aprendido |

## Introduction script (English, about 2.5 minutes)

> Good morning. We are SuperPoderosos, and this is CircleGuard, a contact-tracing system for a university campus. It finds groups of people who shared a space and applies health fences, without revealing who anyone is.
>
> In Part 1 we built a delivery pipeline around eight microservices: every change is built, tested, analyzed and packaged as an immutable versioned image. It is deployed to dev, tested end to end against the real services, promoted to stage, and only reaches production when an authorized person approves it.
>
> In Part 2 we moved the platform to infrastructure as code and Kubernetes. Terraform now describes the network, the k3s clusters, the registry, storage and monitoring for three environments. The pipeline plans every infrastructure change, scans images and infrastructure code for vulnerabilities, deploys to the cluster and rolls back automatically if a rollout fails. On top of that we added resilience patterns, metrics, alerts, tracing, centralized logs, load tests and security tests.
>
> In the next twenty minutes each of us will show the part we built, starting with the infrastructure.

## Demo 1: de un commit a prod con aprobación (Juan Camilo, 5 min)

Preparación antes de la sustentación: un PR pequeño listo (por ejemplo, un texto del cliente web), Jenkins con `CG_DEPLOY_PLATFORM` en la plataforma que esté funcionando, un usuario aprobador con sesión abierta y una versión anterior desplegada en stage para el rollback.

1. Mostrar el PR en GitHub con el estado `continuous-integration/jenkins/pr-head` en verde y, si toca Terraform, el plan archivado en el build.
2. Merge a main. En Jenkins (Blue Ocean o vista de etapas): detección de cambios, build, Sonar, `Trivy IaC Scan`, `Build Images`, `Trivy Image Scan` y `Publish Images to Nexus`.
3. Abrir el reporte JUnit de Trivy y explicar que un HIGH o CRITICAL detiene el build antes de publicar.
4. Seguir dev, E2E y la promoción a stage. Mostrar `reports/ci/promotion-stage.json`.
5. En `Approve prod release`, aprobar con un RFC. Mostrar `prod-approval.json` y la notificación de Discord.
6. Rollback: un build con `ROLLBACK_ENV=stage`, mostrar `rollback-before-stage.txt` y `rollback-after-stage.txt`.

Plan B si el pipeline completo no alcanza en el tiempo: tener abierto un build exitoso anterior y recorrer sus etapas y artefactos.

## Demo 2: falla provocada, alerta y traza (Esteban y Santiago, 5 min)

1. En Grafana, dashboard de negocio y de servicios en estado normal.
2. Escalar a cero `promotion` (o inyectar la falla de US-40) y enviar un cuestionario desde el cliente web.
3. Mostrar el circuito abierto, la alerta en Alertmanager y la notificación.
4. En Jaeger, la traza `form → Kafka → promotion → notification`; desde Loki, saltar del log a la traza con el `traceId`.
5. Restaurar el servicio y mostrar que el circuito se cierra.

## Resultados de Locust (Esteban, 2 min)

Objetivo declarado antes de la prueba, p95, throughput y tasa de error contra ese objetivo, y la captura del HPA escalando durante la carga (US-37 CA4).

## Diapositivas

Una diapositiva por bloque de la tabla, con el diagrama de arquitectura de la Parte 2 al inicio y la tabla de entregables (de la Sprint Review) al cierre. Cada demo tiene una diapositiva de respaldo con capturas por si falla la red.

## Ensayo

Un ensayo completo el domingo 22 con cronómetro. Cada bloque que pase de su tiempo se recorta en el bloque, no en el cierre.
