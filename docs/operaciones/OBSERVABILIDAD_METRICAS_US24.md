# Métricas con Prometheus y dashboards técnicos (`US-24` / `SCRUM-93`)

Responsable: Esteban Cuéllar. Esta historia deja los 8 servicios exponiendo métricas, Prometheus recogiéndolas y Grafana mostrándolas por ambiente y servicio. Es la base de los dashboards de negocio y las alertas de `US-41` y del trazado de `US-25`.

## 1. Criterios de aceptación y evidencia

| Criterio | Cómo se cumple | Evidencia |
| :--- | :--- | :--- |
| **CA1**: los servicios exponen métricas Micrometer que Prometheus recoge | Los 8 servicios agregan `micrometer-registry-prometheus` y exponen `/actuator/prometheus`. Prometheus descubre los pods en Kubernetes (`observability/prometheus/prometheus.yml`) o los recoge por nombre en compose (`prometheus-compose.yml`). | `bash observability/scripts/validate-metrics.sh`, la página *Status → Targets* de Prometheus en `UP` |
| **CA2**: Grafana tiene dashboards técnicos por servicio | Dashboard `CircleGuard · Servicios (técnico)` provisionado desde el repositorio: disponibilidad, peticiones por segundo, errores 4xx/5xx, latencia p95/p99, endpoints más lentos, heap, CPU, hilos y pausas de GC. | `observability/grafana/dashboards/circleguard-servicios-tecnico.json`, captura del dashboard |
| **CA3**: las consultas distinguen ambiente y servicio | Cada servicio etiqueta todas sus métricas con `application` y `environment` (`management.metrics.tags`). El dashboard tiene las variables **Ambiente** y **Servicio**, y todas las consultas las usan. | `application.yml` de cada servicio, variables del dashboard |

## 2. Qué cambió en los servicios

En cada `services/circleguard-*-service`:

- `build.gradle.kts`: `runtimeOnly("io.micrometer:micrometer-registry-prometheus")` (versión gestionada por Spring Boot 3.2).
- `application.yml`:

```yaml
management:
  metrics:
    tags:
      application: ${spring.application.name}
      environment: ${CG_ENVIRONMENT:${spring.profiles.active:local}}
    distribution:
      percentiles-histogram:
        http.server.requests: true     # permite calcular p95/p99 en Prometheus
      slo:
        http.server.requests: 100ms,300ms,1s
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
```

- `identity-service` tiene Spring Security con `anyRequest().authenticated()`, así que se abrió `/actuator/prometheus` junto a `health` e `info`. `auth` y `promotion` ya dejaban pasar `/actuator/**`.

El ambiente sale de `CG_ENVIRONMENT` o, si no está, del perfil activo (`SPRING_PROFILES_ACTIVE`, que los compose ya fijan en `dev`, `stage` o `prod`).

`/actuator/prometheus` solo expone métricas técnicas (sin datos de usuarios). En Kubernetes no tiene Ingress: solo Prometheus llega a él por la NetworkPolicy de la sección 4.

## 3. Estructura

```
observability/
├── kustomization.yaml               base de Kubernetes (Prometheus + Grafana)
├── namespace.yaml                   namespace circleguard-observability
├── prometheus.yaml                  ServiceAccount, RBAC de solo lectura, Deployment y Service
├── grafana.yaml                     Deployment y Service (contraseña desde el Secret grafana-admin)
├── allow-prometheus-scrape.yaml     NetworkPolicy para entrar al namespace del ambiente
├── prometheus/prometheus.yml        configuración para Kubernetes (descubrimiento de pods)
├── prometheus/prometheus-compose.yml configuración para los ambientes en Docker Compose
├── grafana/provisioning/            datasource y proveedor de dashboards
├── grafana/dashboards/              dashboards versionados (JSON)
├── docker-compose.observability.yml Prometheus + Grafana junto a un compose
└── scripts/                         validación y creación del Secret de Grafana
```

Los overlays de cada ambiente están en `deploy/observability/{dev,stage,prod}/`: el namespace de la NetworkPolicy y la etiqueta de ambiente. Van fuera de `observability/` porque kustomize no acepta una base que contenga a sus propios overlays.

## 4. Contrato para los manifiestos de los servicios (`US-37`)

Para que Prometheus recoja un servicio en Kubernetes, la plantilla del pod debe llevar:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: circleguard-form-service   # se usa como "application"
    circleguard.io/metrics: "true"                     # la NetworkPolicy deja entrar a Prometheus
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/path: /actuator/prometheus
    prometheus.io/port: "8086"                         # puerto HTTP del servicio
```

| Servicio | Puerto |
| :--- | :--- |
| identity | 8083 |
| auth | 8180 |
| dashboard | 8084 |
| file | 8085 |
| form | 8086 |
| gateway | 8087 |
| promotion | 8088 |
| notification | 8082 |

El namespace del ambiente niega toda entrada que no venga del mismo namespace (`US-21`). `allow-prometheus-scrape.yaml` agrega una excepción solo para el pod de Prometheus y solo hacia pods con `circleguard.io/metrics: "true"`.

## 5. Cómo desplegarlo

### 5.1 Kubernetes (k3s de cada ambiente)

```bash
GRAFANA_ADMIN_PASSWORD='<contraseña>' bash observability/scripts/create-grafana-secret.sh
kubectl apply -k deploy/observability/dev        # o stage / prod
kubectl -n circleguard-observability rollout status deploy/prometheus deploy/grafana
kubectl -n circleguard-observability port-forward svc/grafana 3000:3000
kubectl -n circleguard-observability port-forward svc/prometheus 9090:9090
```

### 5.2 Docker Compose (mientras los servicios corren con `deploy/compose`)

En el nodo del ambiente, después de levantar el compose del ambiente:

```bash
GRAFANA_ADMIN_PASSWORD='<contraseña>' CG_ENV=dev \
  docker compose -f observability/docker-compose.observability.yml up -d
```

Los puertos quedan solo en `127.0.0.1` del nodo. Desde el computador:

```bash
ssh -i proyectoIngeClave.pem -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ec2-user@<IP del nodo>
```

Luego abrir `http://localhost:9090/targets` (todos en `UP`) y `http://localhost:3000` (carpeta **CircleGuard**).

## 6. Validación

```bash
bash observability/scripts/validate-metrics.sh
```

Revisa los 8 servicios (dependencia, endpoint y etiquetas), la configuración de Prometheus, el dashboard (JSON válido, filtros de ambiente y servicio, métricas operativas) y los overlays. Si encuentra `promtool`, `docker` o `kubectl`, también valida la configuración con `promtool check config` y genera los overlays. Ambas configuraciones de Prometheus pasan `promtool check config` (v2.53.4).

Comprobación en un servicio corriendo:

```bash
curl -s http://localhost:8087/actuator/prometheus | grep 'http_server_requests_seconds_count' | head
# ... application="circleguard-gateway-service",environment="dev",...
```

## 7. Decisiones y trade-offs

- **Prometheus por anotaciones y no Prometheus Operator.** El Operator trae CRDs, webhooks y más memoria; con nodos `m7i-flex.large` y 8 vCPU de cuota, unos pocos manifiestos simples son más baratos y fáciles de explicar. Si el clúster crece, se puede migrar a `ServiceMonitor` sin tocar los servicios.
- **Almacenamiento `emptyDir` con retención de 7 días y 4 GB.** Basta para el proyecto y no ocupa volúmenes EBS. Si el pod se reinicia, se pierde el histórico (aceptable para un ambiente académico; en producción real iría a un PVC o a almacenamiento remoto).
- **Histograma de `http.server.requests`.** Permite calcular p95/p99 en Prometheus y agregarlos entre réplicas, a costa de más series por endpoint.
- **Grafana sin Ingress.** Se consulta por `port-forward` o túnel SSH; así no se expone un panel con contraseña a internet.
