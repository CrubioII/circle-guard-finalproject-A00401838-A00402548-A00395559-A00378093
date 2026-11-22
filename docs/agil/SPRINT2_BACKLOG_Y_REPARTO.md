# Sprint 2 (Parte 2): backlog de historias y reparto por persona

Equipo SuperPoderosos (Grupo 5). Entrega: domingo 22 de noviembre de 2026, 23:59.

El backlog preliminar de la Parte 2 (US-20 a US-29, 76 SP) tenía historias de 8 a 13 SP que mezclaban entregables. Aquí se parten en 26 historias de 2 a 8 SP para que cada una quepa en una rama y un PR. Se conservan los IDs US-20 a US-29 para no romper la trazabilidad con Jira, y las historias nuevas siguen la numeración desde US-35 (US-30 a US-34 ya se usaron en el Sprint 1).

Total: 100 SP, unos 25 SP por persona.

## 1. Épicas y peso en la rúbrica

| Épica | Entregable | Peso P2 | Historias | SP |
| :--- | :---: | :---: | :--- | :---: |
| EPIC-09 IaC con Terraform | E2.1 | 4.0% | US-20, US-35, US-36 | 14 |
| EPIC-10 Orquestación en Kubernetes | E2.2 | 2.0% | US-21, US-37 | 13 |
| EPIC-11 Pipeline incrementado | E2.3 | 1.0% | US-22, US-38, US-39 | 11 |
| EPIC-12 Patrones de diseño | E2.4 | 4.0% | US-23, US-40, US-41, US-42 | 13 |
| EPIC-13 Observabilidad | E2.5 | 4.0% | US-24, US-43, US-25, US-44 | 18 |
| EPIC-14 Seguridad | E2.6 | 2.0% | US-26, US-45 | 8 |
| EPIC-15 Pruebas avanzadas | E2.7 | 2.5% | US-27, US-46, US-47 | 10 |
| EPIC-16 Change management y rollback | E2.8 | 0.5% | US-28 | 3 |
| EPIC-17 Cierre ágil, documentación y sustentación | E2.9, E2.10 | 5.0% | US-29, US-48, US-49 | 10 |

## 2. Historias de usuario

### EPIC-09 IaC con Terraform

**US-20 Backend remoto de Terraform con bloqueo (3 SP).** Como equipo de plataforma quiero guardar el estado de Terraform en S3 con bloqueo en DynamoDB para que dos personas o el pipeline no corrompan el estado.
- CA1: existe `infra/terraform/bootstrap/` que crea el bucket S3 (versionado, cifrado, sin acceso público) y la tabla DynamoDB de locks.
- CA2: cada ambiente usa `backend "s3"` con su propia `key` y `dynamodb_table`.
- CA3: un `terraform plan` simultáneo desde dos máquinas muestra el error de lock (captura como evidencia).

**US-35 Módulos Terraform reutilizables (8 SP).** Como equipo de plataforma quiero módulos para red, clúster, registro, almacenamiento y observabilidad para no duplicar código entre ambientes.
- CA1: `infra/terraform/modules/{network,cluster,registry,storage,observability}` con `variables.tf`, `outputs.tf` y README.
- CA2: `network` crea VPC, subredes y security groups; `cluster` crea las EC2 y arranca k3s con `user_data`; `registry` define ECR (o documenta Nexus existente); `storage` crea los volúmenes y buckets necesarios.
- CA3: `terraform validate` y `tflint` pasan en todos los módulos.
- CA4: todos los recursos quedan en la Región seleccionada del proyecto AWS.

**US-36 Tres ambientes parametrizados y diagrama de infraestructura (3 SP).** Como equipo quiero `dev`, `stage` y `prod` declarados con los mismos módulos y distintas variables.
- CA1: `infra/terraform/envs/{dev,stage,prod}` solo contienen llamadas a módulos y `terraform.tfvars`.
- CA2: `terraform plan` sale limpio (sin cambios) después de un `apply`.
- CA3: diagrama en `docs/arquitectura/` coherente con lo desplegado.

### EPIC-10 Orquestación en Kubernetes

**US-21 Manifiestos Kustomize para los 8 servicios y el middleware (8 SP).** Como equipo quiero desplegar los 8 microservicios, el cliente web y el middleware en Kubernetes por ambiente.
- CA1: `deploy/k8s/base` y `deploy/k8s/overlays/{dev,stage,prod}` con un namespace por ambiente.
- CA2: Deployments/StatefulSets para PostgreSQL, Neo4j, Kafka, Redis y OpenLDAP con volúmenes persistentes.
- CA3: los 8 servicios (incluidos `notification`, `file` y `dashboard`, que en la Parte 1 solo se empaquetaron) y `mobile` corren con imágenes SemVer, nunca `latest`.
- CA4: configuración en ConfigMaps y credenciales en Secrets.

**US-37 Ingress, HPA y sondas Actuator (5 SP).** Como operador quiero que el clúster reinicie pods caídos, escale con carga y exponga la app por un único punto de entrada.
- CA1: `livenessProbe` y `readinessProbe` usan `/actuator/health/liveness` y `/actuator/health/readiness`.
- CA2: HPA por CPU en al menos `gateway`, `form` y `promotion`, con metrics-server instalado.
- CA3: Ingress (Traefik de k3s o NGINX) enruta al gateway y al cliente web.
- CA4: evidencia de un HPA escalando durante la prueba de Locust.

### EPIC-11 Pipeline incrementado

**US-22 Etapas `terraform plan/apply` en Jenkins (3 SP).** Como equipo quiero que Jenkins ejecute Terraform con aprobación antes de tocar prod.
- CA1: `plan` en cada PR que modifique `infra/terraform/`, con el plan archivado como artefacto.
- CA2: `apply` automático en dev y stage; en prod espera el `input` de los aprobadores ya definidos en US-31.

**US-38 Escaneo Trivy bloqueante (3 SP).** Como equipo quiero que el pipeline falle si una imagen o el IaC tienen vulnerabilidades altas.
- CA1: `trivy image` sobre las 9 imágenes y `trivy config` sobre `infra/terraform` y `deploy/k8s`.
- CA2: severidad `HIGH,CRITICAL` con `--exit-code 1`; excepciones justificadas en `.trivyignore`.
- CA3: reportes publicados en Jenkins.

**US-39 Despliegue y promoción en Kubernetes (5 SP).** Como equipo quiero que el pipeline despliegue en el clúster y promueva dev, stage y prod.
- CA1: `kubectl apply -k` por overlay con la etiqueta SemVer calculada en US-12.
- CA2: `kubectl rollout status` como verificación; si falla, la etapa falla.
- CA3: promoción automática a stage tras E2E y aprobación manual a prod.
- CA4: notificación de éxito y fallo (correo o Slack).

### EPIC-12 Patrones de diseño

**US-23 Catálogo de patrones existentes (2 SP).** Como evaluador quiero ver qué patrones ya usa CircleGuard, con evidencia en el código.
- CA1: `docs/patrones/PATRONES_EXISTENTES.md` cubre database-per-service, arquitectura dirigida por eventos (Kafka), API Gateway, cache-aside (Redis) y máquina de estados de salud, cada uno con ruta de archivo y línea.

**US-40 Patrón de resiliencia con Resilience4j (5 SP).** Como usuario quiero que una caída de un servicio no tumbe a los demás.
- CA1: Circuit Breaker y Retry en una llamada síncrona entre servicios (por ejemplo gateway hacia identity o promotion), con fallback.
- CA2: prueba con falla inyectada (WireMock o Testcontainers detenido) que demuestra apertura y cierre del circuito.
- CA3: métricas del circuito visibles en Prometheus.
- CA4: documento con propósito, trade-offs y evidencia en `docs/patrones/`.

**US-41 Patrón de configuración: Feature Toggle / External Configuration (3 SP).** Como operador quiero activar o desactivar una funcionalidad sin recompilar.
- CA1: un toggle leído desde ConfigMap (por ejemplo, habilitar notificaciones por correo o el modo estricto del QR).
- CA2: prueba unitaria con el toggle encendido y apagado, y demostración cambiando el ConfigMap en el clúster.
- CA3: documento con propósito, trade-offs y evidencia.

**US-42 Patrón adicional: Bulkhead / Rate Limiter o Dead Letter Queue (3 SP).** Como equipo quiero un tercer patrón que proteja un punto débil real.
- CA1: opción recomendada, Dead Letter Topic en el consumidor Kafka de `promotion`, o Rate Limiter en la validación de QR del gateway.
- CA2: prueba que provoca el caso (mensaje envenenado o ráfaga) y verifica el comportamiento.
- CA3: documento con propósito, trade-offs y evidencia.

### EPIC-13 Observabilidad

**US-24 Métricas con Micrometer y Prometheus (5 SP).** Como operador quiero métricas técnicas y de negocio de los 8 servicios.
- CA1: `micrometer-registry-prometheus` y `/actuator/prometheus` en los 8 servicios.
- CA2: Prometheus (kube-prometheus-stack o manifiestos propios) descubre los servicios.
- CA3: métricas de negocio propias: cuestionarios enviados, promociones por minuto, check-ins/validaciones de QR, tiempo de contención.

**US-43 Dashboards en Grafana y alertas en Alertmanager (5 SP).** Como operador quiero ver el estado del sistema y enterarme cuando algo falla.
- CA1: un dashboard por servicio (latencia, errores, JVM) y uno de negocio, exportados como JSON en `observability/grafana/`.
- CA2: al menos 3 alertas críticas en `observability/alerts/` (servicio caído, tasa de error 5xx alta, lag de Kafka o circuito abierto).
- CA3: cada alerta probada provocando la falla, con captura.

**US-25 Trazado distribuido con Jaeger (5 SP).** Como desarrollador quiero seguir una petición de `form` a `notification` pasando por Kafka.
- CA1: agente o SDK de OpenTelemetry en `form`, `promotion` y `notification` (y en el gateway).
- CA2: propagación de contexto en los headers de Kafka.
- CA3: captura de Jaeger con una traza completa `form → Kafka → promotion → notification`.

**US-44 Logs centralizados con Loki (3 SP).** Como operador quiero buscar logs de todos los pods en un solo lugar.
- CA1: Loki y Promtail (o Grafana Alloy) desplegados en el clúster.
- CA2: datasource de Loki en Grafana y una consulta guardada por servicio.
- CA3: el `traceId` aparece en los logs para saltar de un log a su traza.

### EPIC-14 Seguridad

**US-26 Secretos fuera del repositorio y RBAC (5 SP).** Como equipo quiero que ninguna credencial viva en Git y que cada actor tenga solo los permisos que necesita.
- CA1: los Secrets de Kubernetes se crean desde Jenkins Credentials o AWS SSM Parameter Store (o Sealed Secrets), nunca en texto plano en `deploy/k8s`.
- CA2: ServiceAccount de Jenkins con Role/RoleBinding limitado a los namespaces de la app.
- CA3: RBAC en Jenkins (Matrix o Role-based Strategy) con roles de admin, desarrollador y aprobador.
- CA4: escaneo de secretos (gitleaks o `trivy fs --scanners secret`) en el pipeline.
- CA5: la llave `.pem` que está en la raíz del repo local queda fuera del repositorio y se rota.

**US-45 TLS en servicios expuestos y escaneo de dependencias (3 SP).** Como usuario quiero que el tráfico hacia la app vaya cifrado.
- CA1: cert-manager con Let's Encrypt (o certificado autofirmado justificado por no tener dominio) en el Ingress.
- CA2: `curl -v https://...` muestra el certificado válido; HTTP redirige a HTTPS.
- CA3: escaneo de dependencias Gradle y npm (`trivy fs` u OWASP Dependency-Check) en el pipeline.

### EPIC-15 Pruebas avanzadas

**US-27 Pruebas de rendimiento con Locust (5 SP).** Como equipo quiero saber cuánta carga soporta el sistema frente a un objetivo declarado.
- CA1: `tests/performance-locust/` con escenarios de validación de acceso QR y envío de cuestionario.
- CA2: objetivo declarado antes de correr (por ejemplo p95 < 500 ms, error < 1%, N usuarios concurrentes).
- CA3: resultados en CSV/HTML con p95, throughput y tasa de error, y una etapa opcional en Jenkins contra stage.

**US-46 OWASP ZAP baseline en el pipeline (3 SP).** Como equipo quiero un análisis dinámico de seguridad en cada despliegue a stage.
- CA1: `zap-baseline.py` contra el Ingress de stage dentro de Jenkins.
- CA2: reporte HTML publicado; reglas aceptadas documentadas en `tests/security-zap/`.

**US-47 Informe consolidado de pruebas y calidad (2 SP).** Como evaluador quiero un solo documento con los resultados de todas las pruebas.
- CA1: `docs/operaciones/INFORME_PRUEBAS.md` con cobertura JaCoCo, SonarQube, integración, E2E, Locust, ZAP y Trivy.
- CA2: cada resultado se compara con su objetivo y se proponen mejoras.

### EPIC-16 Change management y rollback

**US-28 Rollback ejecutado en Kubernetes y registro de cambios (3 SP).** Como operador quiero volver a la versión estable anterior en minutos.
- CA1: `infra/scripts/rollback.sh` (o una etapa de Jenkins) soporta `kubectl rollout undo` o redeploy de la etiqueta anterior.
- CA2: rollback ejecutado en stage o prod con capturas antes y después.
- CA3: release notes por cada versión publicada y `docs/release-notes/REGISTRO_CAMBIOS_POR_AMBIENTE.md`.

### EPIC-17 Cierre ágil, documentación y sustentación

**US-29 Ceremonias y métricas del Sprint 2 (3 SP).** Como Scrum Master quiero documentar planning, review y retrospectiva del Sprint 2 con métricas.
- CA1: `docs/agil/SPRINT_2_CEREMONIAS.md` con planning, dailies resumidas, review y retro.
- CA2: burndown o flujo acumulado exportado de Jira, comparado con el Sprint 1.

**US-48 Documentación final (5 SP).** Como evaluador quiero documentación coherente con lo desplegado.
- CA1: arquitectura actualizada, IaC, patrones y resultados enlazados desde el README.
- CA2: `docs/costos/` con estimación (AWS Pricing Calculator) frente a costo real (Billing and Cost Management).
- CA3: `docs/operaciones/MANUAL_OPERACIONES.md` (arranque, despliegue, rollback, alertas, `terraform destroy`).
- CA4: Executive Summary en inglés de una página, `IAG_REGISTRO.md` actualizado e informe PDF de la Parte 2.

**US-49 Presentación y guion de demo (2 SP).** Como equipo quiero una sustentación de 20 a 30 minutos ensayada.
- CA1: diapositivas con introducción en inglés de 2 a 3 minutos.
- CA2: guion de demo: un commit que llega a prod con aprobación, la app en K8s, una falla provocada que dispara alerta y traza, y resultados de Locust.
- CA3: cada integrante presenta la parte que construyó.

## 3. Reparto por persona

El reparto sigue los roles que cada uno tuvo en el Sprint 1 (`docs/agil/MARCO_AGIL.md`).

### Juan Pablo Ordoñez (Backend & Cloud Infrastructure): 25 SP

| Historia | SP |
| :--- | :---: |
| US-20 Backend remoto S3 + DynamoDB | 3 |
| US-35 Módulos Terraform | 8 |
| US-36 Ambientes y diagrama de infraestructura | 3 |
| US-21 Manifiestos Kustomize de servicios y middleware | 8 |
| US-44 Logs centralizados con Loki | 3 |

Es el camino crítico: sin clúster nadie puede desplegar. Debe tener k3s arriba en dev el primer día.

### Juan Camilo Rubio (Scrum Master & DevOps Lead): 26 SP

| Historia | SP |
| :--- | :---: |
| US-22 Terraform en Jenkins | 3 |
| US-38 Trivy bloqueante | 3 |
| US-39 Despliegue y promoción en K8s | 5 |
| US-28 Rollback en K8s y registro de cambios | 3 |
| US-23 Catálogo de patrones existentes | 2 |
| US-29 Ceremonias y métricas del Sprint 2 | 3 |
| US-48 Documentación final (coordina, cada uno aporta su sección) | 5 |
| US-49 Presentación y guion de demo | 2 |

### Esteban Cuéllar (QA Automation & Test Lead): 25 SP

| Historia | SP |
| :--- | :---: |
| US-40 Resiliencia con Resilience4j | 5 |
| US-24 Micrometer y Prometheus | 5 |
| US-43 Dashboards Grafana y alertas | 5 |
| US-27 Locust | 5 |
| US-46 OWASP ZAP | 3 |
| US-47 Informe consolidado de pruebas | 2 |

### Santiago Castillo (Frontend & Security): 24 SP

| Historia | SP |
| :--- | :---: |
| US-26 Secretos y RBAC | 5 |
| US-45 TLS y escaneo de dependencias | 3 |
| US-37 Ingress, HPA y sondas | 5 |
| US-41 Feature Toggle / External Configuration | 3 |
| US-42 Patrón adicional (DLQ o Rate Limiter) | 3 |
| US-25 Trazado distribuido con Jaeger | 5 |

## 4. Dependencias y orden de trabajo

Quedan cuatro días hasta la entrega, así que el trabajo de código arranca en paralelo con la infraestructura y se integra cuando el clúster esté listo.

| Día | Juan Pablo | Juan Camilo | Esteban | Santiago |
| :--- | :--- | :--- | :--- | :--- |
| Mié 18 - Jue 19 | US-20, US-35 (k3s en dev) | US-38, US-23, planning (US-29) | US-40, US-24 en código | US-41, US-42, US-25 en código |
| Vie 20 | US-21, US-36 | US-22, US-39 | US-43 (stack de monitoreo en el clúster) | US-37, US-26 |
| Sáb 21 | US-44, apoyo a despliegue en stage/prod | US-28, inicio US-48 | US-27, US-46 | US-45, trazas en el clúster |
| Dom 22 | Sección IaC y costos de US-48 | US-48, US-49, review y retro | US-47 | Sección seguridad y patrones de US-48 |

Dependencias fuertes:
- US-21, US-37, US-39, US-43, US-44 y US-45 necesitan el clúster de US-35.
- US-43 necesita las métricas de US-24; las alertas de circuito abierto necesitan US-40.
- US-27 y US-46 necesitan el Ingress de US-37 en stage.
- US-28 necesita US-39 desplegando con etiquetas SemVer.
- US-48 y US-49 consumen las evidencias de todos.

## 5. Bonificaciones (solo si lo obligatorio está completo)

- FinOps (+0.10): presupuesto en AWS Budgets, etiquetas de costo en Terraform y apagado programado de dev/stage. Encaja con Juan Pablo.
- Chaos engineering (+0.10): Chaos Mesh o Litmus matando pods de `promotion` mientras se mira el Circuit Breaker. Encaja con Esteban.
