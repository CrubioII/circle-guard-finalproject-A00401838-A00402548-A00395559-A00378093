# Dashboards de negocio y alertas críticas (`US-41` / `SCRUM-122`)

Responsable: Santiago Castillo. Construye sobre `US-24` (Prometheus + Grafana, `docs/operaciones/OBSERVABILIDAD_METRICAS_US24.md`): los servicios ahora publican métricas de negocio, Grafana tiene un dashboard de negocio y Prometheus evalúa reglas críticas que Alertmanager notifica por correo.

## 1. Criterios de aceptación y evidencia

| Criterio | Cómo se cumple | Evidencia |
| :--- | :--- | :--- |
| **CA1**: Grafana muestra tiempo de contención, promociones por minuto y check-ins | `promotion-service` publica `circleguard_promotions_total`, `circleguard_containment_seconds` y `circleguard_contacts_fenced_total`; `gateway-service` publica `circleguard_checkins_total`. El dashboard **CircleGuard · Negocio y alertas** los muestra. | `observability/grafana/dashboards/circleguard-negocio.json`, captura `evidencias/us41-dashboard-negocio.png` |
| **CA2**: al menos tres reglas críticas con umbral y canal | Cuatro reglas `severity: critical` en `observability/prometheus/rules/alertas-criticas.yml` (tabla de la sección 3). Alertmanager las envía por correo al receptor `guardia-circleguard`. | `promtool check rules`, `promtool test rules` y `amtool check-config` en verde, `observability/alertmanager/alertmanager.yml` |
| **CA3**: una alerta verificada de extremo a extremo con evidencia | `observability/scripts/demo-alerta.sh` detiene `gateway-service`, espera el correo `[FIRING] CircleGuardServicioCaido` en Mailpit, lo vuelve a levantar y espera el `[RESOLVED]`. | Sección 5 y capturas en `docs/operaciones/evidencias/` |

## 2. Métricas de negocio

| Métrica (Prometheus) | Servicio | Qué mide | Cómo se lee |
| :--- | :--- | :--- | :--- |
| `circleguard_promotions_total{status}` | promotion | Cambios de estado de salud aplicados (SUSPECT, CONFIRMED, …) | `rate(...[5m]) * 60` = promociones por minuto |
| `circleguard_containment_seconds{status}` | promotion | **Tiempo de contención**: desde que llega el cambio de estado hasta que los contactos quedan cercados en Neo4j, la caché de Redis actualizada y el evento publicado en Kafka | `histogram_quantile(0.95, ...)` = p95. Tiene cubetas en 300 ms y 1 s (NFR-1) |
| `circleguard_contacts_fenced_total{status}` | promotion | Contactos que el cerco movió a SUSPECT o PROBABLE | `increase(...[1h])` = contactos cercados en la última hora |
| `circleguard_checkins_total{result}` | gateway | Validaciones de QR en la puerta: `granted`, `denied` (riesgo de salud) o `invalid` (QR malo o vencido) | `rate(...[5m]) * 60` = check-ins por minuto |

Se instrumentan con Micrometer en dos clases pequeñas, `PromotionMetrics` y `CheckInMetrics`, para que la lógica de negocio solo diga "terminó una promoción" o "se permitió un check-in". Ninguna métrica lleva identificadores de usuario: las etiquetas son solo el estado o el resultado, así que no hay datos personales y la cardinalidad es baja.

## 3. Reglas críticas

| Alerta | Condición (umbral) | Durante | Por qué es crítica |
| :--- | :--- | :--- | :--- |
| `CircleGuardServicioCaido` | `up{job="circleguard-services"} == 0` | 1 min | Un servicio caído deja sin validar puertas o sin cercar contactos |
| `CircleGuardContencionLenta` | p95 de `circleguard_containment_seconds` > 1 s | 2 min | Incumple NFR-1: los contactos tardan en quedar cercados |
| `CircleGuardErroresHttp5xx` | más del 5 % de peticiones con 5xx por servicio | 5 min | Degradación visible para los usuarios |
| `CircleGuardBroteDeConfirmados` | más de 5 casos `CONFIRMED` por minuto | 2 min | Señal temprana de brote para el comité de salud |

`for` evita falsas alarmas: la condición debe mantenerse ese tiempo antes de avisar. Una regla de inhibición calla `ErroresHttp5xx` de un servicio si ya está avisando `ServicioCaido` del mismo.

## 4. Canal de notificación

Prometheus envía las alertas a Alertmanager (`alerting` en `prometheus-compose.yml`). Alertmanager las agrupa por `alertname`, `environment` y `application` (un correo por servicio), espera 10 s para juntar las del mismo grupo y manda **un correo** a `guardia@circleguard.local`, también cuando la alerta se resuelve (`send_resolved`). En los ambientes compose el SMTP es **Mailpit**, una bandeja de prueba en `http://127.0.0.1:8025`; para producción basta con cambiar `smtp_smarthost` y las credenciales en `observability/alertmanager/alertmanager.yml`.

En Kubernetes Prometheus ya carga las mismas reglas (configmap `prometheus-config`) y Grafana el dashboard de negocio; desplegar Alertmanager en el clúster queda para una historia aparte.

## 5. Cómo probarlo

```bash
# Ambiente dev (o solo lo necesario para la demo) y observabilidad
docker compose --env-file <env> -f deploy/compose/docker-compose.dev.yml up -d --build \
  postgres neo4j zookeeper kafka redis promotion-service gateway-service
GRAFANA_ADMIN_PASSWORD=<clave> CG_ENV=dev docker compose -f observability/docker-compose.observability.yml up -d

# Tráfico de negocio + alerta de extremo a extremo
NEO4J_PASSWORD=<clave> JWT_SECRET=<jwt> QR_SECRET=<qr> bash observability/scripts/demo-alerta.sh
```

- Grafana (`http://127.0.0.1:3000`, carpeta CircleGuard) → **CircleGuard · Negocio y alertas**.
- Prometheus → *Alerts* muestra las 4 reglas; Alertmanager en `http://127.0.0.1:9093`.
- Mailpit en `http://127.0.0.1:8025` muestra los correos FIRING y RESOLVED.

### Resultado de la verificación

Corrida del 22 de noviembre de 2026 en el Mac, con `postgres`, `neo4j`, `kafka`, `redis`, `promotion-service` y `gateway-service` del compose dev (imágenes construidas desde esta rama) y la observabilidad de este PR. Duración total: 3 minutos.

```text
1) 10 promociones con contactos reales en Neo4j
2) Check-ins con QR inválido
circleguard_checkins_total{...,result="invalid",} 3.0
circleguard_checkins_total{...,result="granted",} 10.0
circleguard_promotions_total{...,status="SUSPECT",} 10.0
circleguard_promotions_total{...,status="CONFIRMED",} 10.0
3) Se detiene gateway-service para disparar CircleGuardServicioCaido (tarda ~2 min)
"state":"active"
   Correo FIRING recibido en http://localhost:8025
4) Se levanta gateway-service y se espera el correo RESOLVED
   Correo RESOLVED recibido. Alerta verificada de extremo a extremo.
```

| Evidencia | Archivo |
| :--- | :--- |
| Dashboard de negocio con tráfico real (p95 de contención ≈ 170 ms, por debajo de NFR-1) | `evidencias/us41-dashboard-negocio.png` |
| Las 4 reglas cargadas en Prometheus | `evidencias/us41-prometheus-reglas.png` |
| Correo `[FIRING]` de `gateway-service` en Mailpit, seguido del `[RESOLVED]` | `evidencias/us41-mailpit-correo-firing.png` |

En la corrida local `auth`, `form` e `identity` no estaban levantados, por eso aparecen también como caídos (3 alertas activas): es el comportamiento esperado de la regla.

Las reglas tienen pruebas unitarias con `promtool` (`observability/prometheus/rules/tests/alertas-criticas.test.yml`):

```bash
docker run --rm --entrypoint promtool -v "$PWD/observability/prometheus/rules:/r:ro" \
  prom/prometheus:v2.53.4 test rules /r/tests/alertas-criticas.test.yml
```

## 6. Hallazgos

- `gateway-service` niega el acceso solo si el estado en Redis es `CONTAGIED` o `POTENTIAL`, pero `promotion-service` escribe `SUSPECT`, `PROBABLE` y `CONFIRMED`. Por eso hoy el contador `denied` casi no sube aunque haya personas cercadas. Es un error previo, fuera del alcance de esta historia.
- Si el usuario no tiene contactos, la consulta Cypher de la promoción no devuelve fila, así que no se publica el evento ni se mide esa promoción. Ya se había documentado en `US-25`; por eso la demo crea cada usuario con un contacto.
