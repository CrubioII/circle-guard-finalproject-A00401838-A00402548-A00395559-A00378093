# Logs centralizados con Loki (`US-42` / `SCRUM-123`)

Esta historia junta en un solo lugar los logs de los 8 microservicios, el web-client y el middleware de cada ambiente, para buscar fallos por servicio, ambiente y período desde Grafana. Se separó del trazado distribuido (`US-25`) para entregarla por su cuenta.

## 1. Criterios de aceptación y evidencia

| Criterio | Cómo se cumple | Evidencia |
| :--- | :--- | :--- |
| **CA1**: los logs de los servicios y el middleware acordados llegan al sistema centralizado | Grafana Alloy lee los logs de **todos los pods** del namespace `circleguard-<env>` y los envía a Loki: auth, identity, promotion, form, gateway, notification, dashboard, file y web-client, además de postgres, neo4j, zookeeper, kafka, redis y openldap. Un pod nuevo entra solo, sin tocar la configuración. | Sección 6: en un k3s 1.37.2 de prueba llegaron los logs de un servicio (`auth-service`) y de un middleware (`postgres`) |
| **CA2**: los logs se filtran al menos por servicio, ambiente y período | Cada línea lleva las etiquetas `environment`, `service`, `component`, `namespace`, `pod`, `container` y `level`. El dashboard **CircleGuard · Logs** tiene los filtros Ambiente, Servicio, Nivel y Texto; el período sale del selector de tiempo de Grafana | `observability/grafana/dashboards/circleguard-logs.json`, consultas de la sección 6 |
| **CA3**: la ruta de consulta y la política de retención quedan documentadas | Secciones 3 y 4 de este documento | Este documento y `bash observability/scripts/validate-logs.sh` |

## 2. Arquitectura

```
namespace circleguard-<env>                     namespace circleguard-observability
┌──────────────────────────────┐   API de      ┌──────────┐  push   ┌──────┐  LogQL  ┌─────────┐
│ servicios, web-client y      │── Kubernetes ─>│  Alloy   │───────> │ Loki │ <────── │ Grafana │
│ middleware (stdout/stderr)   │   (pods/log)   └──────────┘         └──────┘         └─────────┘
└──────────────────────────────┘                                    disco 5 Gi
```

- **Loki 3.7.9**, en modo monolítico: un solo proceso, índice TSDB y chunks en un volumen persistente de 5 Gi.
- **Grafana Alloy v1.21.3** como recolector. Promtail no se usó porque llegó a fin de soporte en 2026. Alloy lee los logs por la API de Kubernetes (`loki.source.kubernetes`) y no monta `/var/log` del nodo con `hostPath`. Por eso el namespace de observabilidad sigue con Pod Security `baseline` y Alloy corre como un Deployment, no como un DaemonSet.
- **Permisos mínimos:** Alloy tiene un `Role` en el namespace de la aplicación, con `get`, `list` y `watch` sobre `pods` y `get` sobre `pods/log`, y nada más. No ve otros namespaces, no lee Secrets y no puede cambiar nada.
- **Sin exposición pública:** ni Loki ni Grafana tienen Ingress. Se llega a ellos con `kubectl port-forward`.
- Cada ambiente tiene su propio clúster (US-20) y su propio Loki, igual que Prometheus y Grafana (US-24).

```
observability/
├── loki.yaml                 StatefulSet y Service de Loki
├── loki/loki.yaml            configuración de Loki (almacenamiento, límites y retención)
├── alloy.yaml                ServiceAccount, Role, RoleBinding y Deployment de Alloy
├── alloy/config.alloy        qué pods leer, qué etiquetas poner y a dónde enviar
├── grafana/provisioning/datasources/loki.yaml   datasource Loki (uid loki)
├── grafana/dashboards/circleguard-logs.json     dashboard CircleGuard · Logs
└── scripts/validate-logs.sh  validación sin clúster
deploy/observability/<env>/   namespace del Role, variables de Alloy y retención por ambiente
```

### Etiquetas

| Etiqueta | Origen | Ejemplo |
| :--- | :--- | :--- |
| `environment` | variable `CG_ENVIRONMENT` del overlay | `prod` |
| `service` | etiqueta `app.kubernetes.io/name` del pod (US-37) | `form-service`, `kafka` |
| `component` | etiqueta `app.kubernetes.io/component` | `backend`, `database` |
| `namespace`, `pod`, `container` | metadatos del pod | `circleguard-prod` |
| `level` | se extrae de la línea (`INFO`, `WARN`, `ERROR`...) | `ERROR` |

`level` solo existe cuando la línea tiene un nivel reconocible. Las líneas de Spring Boot, Kafka y Neo4j lo tienen; las `LOG:` de Postgres no. El filtro Nivel en "All" incluye también las líneas sin nivel.

## 3. Ruta de consulta

### 3.1 Desplegar en un ambiente

La API del clúster (6443) solo acepta la VPC y la IP de Jenkins (US-22). Hay dos formas de desplegar:
- desde un equipo con acceso, con el kubeconfig de administrador;
- desde el propio server por Session Manager, como `install-cert-manager.sh`.

```bash
# Si Grafana todavía no está desplegado (US-24):
GRAFANA_ADMIN_PASSWORD='<contraseña>' bash observability/scripts/create-grafana-secret.sh
kubectl apply -k deploy/observability/dev        # o stage / prod
kubectl -n circleguard-observability rollout status statefulset/loki deploy/alloy deploy/grafana
```

En el server, por Session Manager:

```bash
sudo -i
curl -sfL -o cg.tgz https://codeload.github.com/CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093/tar.gz/refs/heads/main
mkdir -p cg && tar -xzf cg.tgz -C cg --strip-components=1 && cd cg
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl apply -k deploy/observability/dev    # el ambiente del server
cd /root && rm -rf cg cg.tgz
```

### 3.2 Consultar

```bash
kubectl -n circleguard-observability port-forward svc/grafana 3000:3000
```

1. Abre `http://localhost:3000`, entra con el usuario del Secret `grafana-admin` y ve a **Dashboards → CircleGuard → CircleGuard · Logs**.
2. Elige **Ambiente**, **Servicio**, **Nivel**, y si quieres un **Texto** que debe contener la línea. El período se elige en el selector de tiempo, arriba a la derecha.
3. En el dashboard:
   - un panel muestra el volumen de logs por servicio;
   - otro muestra cuántos `ERROR` hubo en el período;
   - el último muestra las líneas, con sus etiquetas al abrir cada una.

Para consultas libres usa **Explore**, con el datasource **Loki**:

```logql
{environment="prod", service="form-service"}                       # todo lo de un servicio
{environment="prod", level="ERROR"}                                # errores de todo el ambiente
{environment="prod", service=~"kafka|zookeeper"} |= "Exception"    # middleware con un texto
{environment="stage", service="promotion-service"} |~ "user-[0-9]+" # expresión regular
sum by (service) (count_over_time({environment="prod", level="ERROR"}[5m]))   # errores por servicio
```

Para la API de Loki, sin Grafana:

```bash
kubectl -n circleguard-observability port-forward svc/loki 3100:3100
curl -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={environment="prod",service="auth-service",level="ERROR"}' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)000000000" --data-urlencode limit=20
```

## 4. Política de retención

| Ambiente | Retención en Loki | `LOKI_RETENTION_PERIOD` | CloudWatch (`observability_log_retention_days`) |
| :--- | :--- | :--- | :--- |
| dev | 7 días | `168h` | 7 |
| stage | 14 días | `336h` | 14 |
| prod | 30 días | `720h` | 30 |

- **Quién la aplica:** el *compactor* de Loki (`retention_enabled: true`). Cada 10 minutos marca los chunks más viejos que la retención, y 2 horas después (`retention_delete_delay`) los borra del disco.
- **Dónde se cambia:** en el overlay del ambiente, `deploy/observability/<env>/kustomization.yaml`, en el parche del StatefulSet `loki`. Hay que mantenerla igual que `observability_log_retention_days` del ambiente en Terraform. `validate-logs.sh` falla si no coinciden.
- **Consultas:** no se puede consultar más atrás que la retención (`max_query_lookback`).
- **Logs viejos:** Loki rechaza líneas de más de 7 días (`reject_old_samples_max_age`).
- **Volumen:** 5 Gi por ambiente. Con los límites de ingesta (4 MB/s, ráfagas de 8 MB), los 30 días de prod caben con el volumen normal de logs. Si el disco se llena, Loki deja de aceptar líneas nuevas. En ese caso se agranda el PVC `data-loki-0` o se baja la retención.
- **Respaldo:** los logs de Loki no se respaldan. Si se borra el volumen o se recrea el clúster, se pierden. Son datos operativos, no registros de auditoría.

## 5. Recursos

| Componente | Pide | Límite |
| :--- | :--- | :--- |
| Loki | 25m CPU, 256 Mi | 500m, 512 Mi |
| Alloy | 25m CPU, 96 Mi | 300m, 256 Mi |
| Prometheus (US-24) | 25m CPU, 256 Mi | 500m, 768 Mi |
| Grafana (US-24) | 25m CPU, 128 Mi | 300m, 384 Mi |

Van en `circleguard-observability`, que no tiene ResourceQuota, así que no cuentan para la cuota de `circleguard-<env>`. Sí cuentan para el nodo, y la CPU es lo que más se agota:
- El nodo `m7i-flex.large` tiene 2000m de CPU para pedir.
- En stage, la aplicación y los pods del sistema ya piden 1850m.
- Con 100m por componente, Loki y Prometheus quedaban en `Pending` por `Insufficient cpu`.
- Con 25m por componente, la observabilidad pide 100m en total y stage queda en 1950m.

Pedir poca CPU solo sirve para que Kubernetes ubique los pods en el nodo; en reposo consumen menos que eso. El límite les deja usar más cuando hacen falta, por ejemplo en una consulta grande o al compactar.

En memoria, stage y prod quedan con unos 6,7 GiB pedidos en total de 8 GiB:
- 6016 Mi de la aplicación;
- 384 Mi de Prometheus y Grafana;
- 352 Mi de Loki y Alloy.

Antes de desplegar en un nodo, o de agregar más pods, revisa lo que queda libre:

```bash
kubectl describe node | sed -n '/Allocated resources/,/Events/p' | head -6
```

## 6. Validación

```bash
bash observability/scripts/validate-logs.sh
```

Revisa los tres criterios sin clúster:
- que Alloy lea solo el namespace del ambiente, con un Role y sin `hostPath`;
- las etiquetas y los filtros del dashboard;
- que la retención de cada overlay coincida con CloudWatch.

Si hay `kubectl` y `docker`, además:
- genera los 3 overlays;
- valida la configuración con `loki -verify-config`;
- revisa la sintaxis de Alloy con `alloy fmt`.

En Git Bash para Windows, las dos pruebas con Docker fallan por la conversión de rutas de los volúmenes. Hay que correrlas en Linux o WSL.

### Prueba en un clúster (k3s 1.37.2 en Docker, 26/11/2026)

La prueba se hizo así:
- se creó el namespace `circleguard-dev` con dos pods de prueba:
  - `auth-service`, que imita un servicio: líneas de Spring Boot `INFO`, y un `ERROR "LDAP timeout"` cada 5;
  - `postgres`, que imita el middleware: líneas `LOG: checkpoint complete`;
- se aplicó `kubectl apply -k deploy/observability/dev`.

| Paso | Resultado |
| :--- | :--- |
| `rollout status` de Loki, Alloy y Grafana | Los tres listos, 0 reinicios |
| Etiquetas en Loki | `component, container, environment, level, namespace, pod, service` |
| Servicios con `{environment="dev"}` | `auth-service`, `postgres` (servicio y middleware, CA1) |
| `{environment="dev", service="auth-service", level="ERROR"}`, últimos 5 min | Las líneas `LDAP timeout request=175`, `170`, `165` (CA2) |
| El mismo filtro entre hace 2 h y hace 1 h | Resultado vacío: el período filtra (CA2) |
| `/config` de Loki | `retention_enabled: true`, `retention_period: 1w` (CA3) |
| Grafana, `/api/datasources/uid/loki/health` | `Data source successfully connected.` |
| Grafana, dashboards | `CircleGuard · Logs` junto a los de US-24 y US-41 |
| Consultas del dashboard con las variables en "All" | Volumen por servicio `auth-service` 161 y `postgres` 93; errores con el texto "LDAP" 27 |
| `trivy config` de `loki.yaml` y `alloy.yaml` | 0 hallazgos HIGH/CRITICAL |
| `kubeconform -strict` de los 3 overlays | 21 recursos válidos en cada uno |

## 7. Límites conocidos

- Solo cubre los ambientes en Kubernetes. Los ambientes en Docker Compose (US-05) no envían logs a Loki; en ellos se usa `docker compose logs`. Esos ambientes están detenidos.
- Si Alloy se reinicia, vuelve a leer los últimos minutos de cada pod. Loki descarta las líneas repetidas que llegan con la misma marca de tiempo.
- Las líneas de un pod que se borró antes de que Alloy las leyera, por ejemplo uno que terminó muy rápido, se pierden. Los logs de un pod que se reinicia sí se leen, porque Kubernetes los guarda hasta que el pod se borra.
- `docker-compose.observability.yml` monta la misma carpeta de datasources, así que en compose Grafana muestra un datasource Loki sin conexión. No afecta a Prometheus.
