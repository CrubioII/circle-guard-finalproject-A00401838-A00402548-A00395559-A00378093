# CircleGuard: informe de la Parte 2

Incremento del Sprint 2: Terraform, Kubernetes, pipeline de plataforma, patrones, observabilidad, seguridad, pruebas avanzadas y change management. Para cada entregable se indica dónde está el código, dónde está la evidencia y qué falta. El informe de la Parte 1 está en [INFORME_PARTE1.md](INFORME_PARTE1.md) y el resumen en inglés en [EXECUTIVE_SUMMARY_EN.md](EXECUTIVE_SUMMARY_EN.md).

## Contenido

1. [Estado por entregable](#1-estado-por-entregable)
2. [E2.1 Terraform](#2-e21-terraform)
3. [E2.2 Kubernetes](#3-e22-kubernetes)
4. [E2.3 Pipeline incrementado](#4-e23-pipeline-incrementado)
5. [E2.4 Patrones de diseño](#5-e24-patrones-de-diseño)
6. [E2.5 Observabilidad](#6-e25-observabilidad)
7. [E2.6 Seguridad](#7-e26-seguridad)
8. [E2.7 Pruebas avanzadas](#8-e27-pruebas-avanzadas)
9. [E2.8 Change management](#9-e28-change-management)
10. [E2.9 Documentación y costos](#10-e29-documentación-y-costos)
11. [Pendientes antes de la sustentación](#11-pendientes-antes-de-la-sustentación)

## 1. Estado por entregable

| Entregable | Estado | Documento principal |
| :--- | :--- | :--- |
| E2.1 Terraform | Completo | [TERRAFORM_PLATAFORMA_US35.md](../arquitectura/TERRAFORM_PLATAFORMA_US35.md), [TERRAFORM_BACKEND_US36.md](../arquitectura/TERRAFORM_BACKEND_US36.md) |
| E2.2 Kubernetes | Completo | [KUBERNETES_PLATAFORMA_US21.md](../arquitectura/KUBERNETES_PLATAFORMA_US21.md), [DESPLIEGUE_SERVICIOS_K8S_US37.md](../arquitectura/DESPLIEGUE_SERVICIOS_K8S_US37.md) |
| E2.3 Pipeline | Completo | [PIPELINE_PLATAFORMA_US22_US38_US39.md](../arquitectura/PIPELINE_PLATAFORMA_US22_US38_US39.md) |
| E2.4 Patrones | Completo | [PATRONES_EXISTENTES.md](../patrones/PATRONES_EXISTENTES.md), [PATRONES_RESILIENCIA_CONFIGURACION_US23.md](../patrones/PATRONES_RESILIENCIA_CONFIGURACION_US23.md), [PATRON_DLQ_US40.md](../arquitectura/PATRON_DLQ_US40.md) |
| E2.5 Observabilidad | Completo | [OBSERVABILIDAD_METRICAS_US24.md](../operaciones/OBSERVABILIDAD_METRICAS_US24.md), [TRAZADO_DISTRIBUIDO_US25.md](../operaciones/TRAZADO_DISTRIBUIDO_US25.md), [DASHBOARDS_ALERTAS_US41.md](../operaciones/DASHBOARDS_ALERTAS_US41.md), [LOGS_CENTRALIZADOS_US42.md](../operaciones/LOGS_CENTRALIZADOS_US42.md) |
| E2.6 Seguridad | Completo | [SEGURIDAD_HARDENING_US26.md](../operaciones/SEGURIDAD_HARDENING_US26.md) |
| E2.7 Pruebas avanzadas | Falta registrar resultados de Locust | [performance/locust/README.md](../../performance/locust/README.md), [SEGURIDAD_ZAP_US44.md](../operaciones/SEGURIDAD_ZAP_US44.md) |
| E2.8 Change management | Falta ejecutar y registrar un rollback en el registro por ambiente | [ROLLBACK_K8S_US28.md](../operaciones/ROLLBACK_K8S_US28.md), [REGISTRO_CAMBIOS_POR_AMBIENTE.md](../release-notes/REGISTRO_CAMBIOS_POR_AMBIENTE.md) |
| E2.9 Documentación | Faltan las ceremonias del Sprint 2 | Este informe, [COSTOS_PARTE2.md](COSTOS_PARTE2.md) |

## 2. E2.1 Terraform

`infra/terraform/` tiene cinco módulos reutilizables y tres ambientes que los usan con variables distintas:

| Módulo | Qué crea |
| :--- | :--- |
| `network` | VPC, subredes pública y privada, Internet Gateway, rutas y flow logs |
| `compute` | Server k3s con IP elástica, security group, rol IAM para Session Manager, token y kubeconfig en SSM |
| `registry` | Repositorio ECR con política de limpieza |
| `storage` | Dos buckets S3 cifrados, versionados y sin acceso público |
| `observability` | Dashboard, alarma y logs en CloudWatch, tema SNS cifrado con KMS |

El estado está en S3 con bloqueo nativo (`use_lockfile`), que reemplaza a la tabla de DynamoDB. El bucket lo crea `infra/terraform/bootstrap/`. Diagramas: `docs/arquitectura/diagramas/terraform-*.svg` e `infraestructura-aws-us36.svg`.

En esta versión el módulo `compute` también escribe `registries.yaml` en los nodos nuevos para que bajen imágenes de Nexus por HTTP (variable `insecure_registries`). El server existente ignora los cambios del launch template, así que no se reinicia.

## 3. E2.2 Kubernetes

`deploy/k8s/` usa Kustomize con una base y un overlay por ambiente:

- Namespaces `circleguard-dev`, `circleguard-stage` y `circleguard-prod`, cada uno con ResourceQuota, LimitRange y NetworkPolicies.
- Middleware como StatefulSets y los 8 servicios y el web-client como Deployments.
- ConfigMaps generados (un cambio de valor reinicia los pods) y Secrets que no están en Git.
- Ingress de Traefik con TLS de cert-manager y redirección a HTTPS.
- Sondas `startupProbe`, `livenessProbe` y `readinessProbe` sobre los grupos de Actuator `/actuator/health/liveness` y `/actuator/health/readiness`.
- HPA por CPU (70 %) para `gateway-service`, `form-service` y `promotion-service`, de 1 a 3 réplicas, dentro de la cuota del namespace.

`deploy/k8s/scripts/validate.sh` valida el esquema de los tres overlays y que quepan en la cuota.

## 4. E2.3 Pipeline incrementado

Las etapas de plataforma están en `jenkins/vars/platformFlow.groovy` y en el `Jenkinsfile`:

1. `Terraform Plan` en los PR y `Terraform Apply <env>` en `main`. El de prod pide aprobación de `CG_PROD_APPROVERS`.
2. Trivy sobre la IaC (bloqueante) y sobre las imágenes. El escaneo de imágenes reporta sin bloquear desde el PR #73, por CVE de las imágenes base (P11).
3. `Deploy to <env>` con `kubectl apply -k` y la versión SemVer, y `Verify <env> health` con `rollout status`. Si falla, rollback automático.
4. E2E y ZAP baseline contra dev antes de promover a stage, y aprobación manual antes de prod.
5. Notificación de fallos en Discord.

## 5. E2.4 Patrones de diseño

Los patrones que el sistema ya traía (database per service, arquitectura dirigida por eventos, API Gateway, cache-aside, máquina de estados) están verificados en el código en `PATRONES_EXISTENTES.md`. Los tres nuevos:

| Patrón | Tipo | Dónde | Prueba |
| :--- | :--- | :--- | :--- |
| Circuit Breaker + Retry | Resiliencia | auth → identity y dashboard → promotion (Resilience4j) | Falla inyectada del servicio llamado |
| External Configuration | Configuración | URLs, timeouts y umbrales por variables de entorno y ConfigMaps | Cambio de valor sin recompilar |
| Reintentos con Dead Letter Topic | Adicional | Consumidor Kafka de `notification-service` | `DeadLetterTopicIntegrationTest` con Kafka embebido |

## 6. E2.5 Observabilidad

- Métricas con Micrometer en `/actuator/prometheus` y dashboards técnicos por servicio en Grafana.
- Dashboard de negocio con tiempo de contención, promociones por minuto y check-ins.
- Cuatro alertas `critical` en Alertmanager. `observability/scripts/demo-alerta.sh` prueba una de extremo a extremo (capturas en `docs/operaciones/evidencias/`).
- Trazas con OpenTelemetry y Jaeger para form → Kafka → promotion → notification.
- Logs centralizados con Loki y Alloy, consultables en Grafana.

## 7. E2.6 Seguridad

- Trivy en el pipeline y escaneo de secretos en el código.
- Secrets fuera de Git, creados con `create-secrets.sh` y cifrados en reposo (`--secrets-encryption` de k3s).
- RBAC en Kubernetes: una ServiceAccount por servicio sin token montado, y Jenkins con la cuenta `jenkins-deployer`, limitada a su namespace y sin acceso a Secrets.
- RBAC en Jenkins por matriz (administrador, equipo y solo lectura). Solo los aprobadores nombrados aprueban prod.
- TLS en el Ingress con cert-manager. Se usa una CA propia porque los hosts `*.circleguard.edu` no son dominios públicos; está justificado en el documento de US-26.

## 8. E2.7 Pruebas avanzadas

- Locust (`performance/locust/`) con escenarios de validación de acceso y envío de cuestionarios. Objetivos: p95 global ≤ 800 ms, p95 de `/api/v1/gate/validate` ≤ 300 ms, más throughput y tasa de error.
- OWASP ZAP baseline en la etapa `ZAP Baseline against dev`, con las excepciones en `.zap/baseline-rules.tsv`.
- Cobertura y calidad: JaCoCo y SonarQube con Quality Gate desde la Parte 1. El informe consolidado de US-44 está en curso en la rama `docs/US-44-consolidated-report`.

Falta: correr Locust contra stage y pegar aquí la tabla de resultados (p95, req/s, % de error frente al objetivo) con su interpretación.

## 9. E2.8 Change management

- Release notes por versión: [v0.1.0](../release-notes/RELEASE_NOTES_v0.1.0.md) y [v0.2.0](../release-notes/RELEASE_NOTES_v0.2.0.md). El pipeline las genera con `generate-release-notes.sh` y desde esta versión publica el tag `vX.Y.Z` en GitHub, así que cada versión nueva parte del tag anterior.
- Rollback automático cuando la verificación falla y manual con `ROLLBACK_ENV` y `ROLLBACK_TARGET_VERSION`.
- Registro de cambios por ambiente en `REGISTRO_CAMBIOS_POR_AMBIENTE.md`.

Falta: ejecutar un rollback en Kubernetes (por ejemplo de 0.2.0 a 0.1.0 en stage), guardar la salida de Jenkins y anotar la fila en el registro.

## 10. E2.9 Documentación y costos

- Arquitectura y diagramas en `docs/arquitectura/`.
- Infraestructura como código en `infra/terraform/README.md`.
- Manual de operaciones: `README.md` (§4 y §5) y los documentos de `docs/operaciones/`.
- Costos estimados y reales en [COSTOS_PARTE2.md](COSTOS_PARTE2.md): unos 310 USD/mes a precio de lista con todo encendido y 21,82 USD de uso real en noviembre, cubiertos por créditos.
- Resumen ejecutivo en inglés en [EXECUTIVE_SUMMARY_EN.md](EXECUTIVE_SUMMARY_EN.md).

## 11. Pendientes antes de la sustentación

| Pendiente | Entregable | Quién lo puede cerrar |
| :--- | :--- | :--- |
| Resultados de Locust con su análisis | E2.7 | Ejecutar `performance/locust/run-load-test.sh` contra stage |
| Rollback evidenciado en Kubernetes y fila en el registro | E2.8 | Build de `main` con los parámetros de rollback |
| Acta del Sprint 2: review, retrospectiva y burndown o flujo acumulado | E2.9 | Exportar de Jira y escribir el acta en `docs/agil/` |
| Crear los Secrets de un ambiente nuevo antes del primer despliegue | E2.2 | Un administrador con `create-secrets.sh --env <env> --generate --if-missing` |
| Revisar el recurso de Lightsail que aparece en la factura | E2.9 | Consola de AWS |
