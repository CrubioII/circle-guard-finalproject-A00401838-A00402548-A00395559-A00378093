# Pruebas de carga con Locust (US-27)

Historia US-27 (SCRUM-96). Mide p95, throughput (req/s) y tasa de error de CircleGuard contra un ambiente desplegado.

## Escenarios

| Usuario simulado | Peso | Flujo | Servicios |
| :--- | :--- | :--- | :--- |
| `CampusEntryUser` | 6 | Login, generar QR y validarlo en la puerta (más un login de vez en cuando) | auth, gateway |
| `SurveyUser` | 3 | Enviar el cuestionario diario de salud, sin síntomas y con un ID anónimo nuevo | form (y por Kafka, promotion) |
| `AdminStatsUser` | 1 | Consultar las estadísticas de salud | promotion |

El peso refleja el tráfico real: la mayoría de las peticiones son de gente entrando al campus.

## Umbrales

| Métrica | Carga (`load`) | Estrés (`stress`) | Variable |
| :--- | :--- | :--- | :--- |
| p95 global | ≤ 800 ms | ≤ 2000 ms | `P95_MS` |
| p95 de `/api/v1/gate/validate` | ≤ 300 ms | ≤ 1000 ms | `GATE_P95_MS` |
| Tasa de error | ≤ 1 % | ≤ 5 % | `MAX_ERROR_RATE` |

La validación en la puerta tiene un umbral más estricto porque hay una persona esperando en el torniquete. Si un umbral se supera, Locust termina con código 1.

## Cómo correrlo

```bash
pip install -r performance/locust/requirements.txt

# Con los túneles SSH al ambiente abiertos (deploy/scripts/run-e2e.sh) o la pila local arriba:
bash performance/locust/run-load-test.sh smoke dev    # 5 usuarios, 1 min
bash performance/locust/run-load-test.sh load dev     # 50 usuarios, 5 min
bash performance/locust/run-load-test.sh stress dev   # 200 usuarios, 5 min
```

Variables:

- `AUTH_URL`, `GATEWAY_URL`, `FORM_URL` y `PROMOTION_URL`: por defecto `127.0.0.1` con los puertos de compose (8180, 8087, 8086 y 8088).
- `LOCUST_USERNAME` y `LOCUST_PASSWORD`: por defecto el usuario sembrado `staff_guard`, el mismo de los E2E.

Los reportes quedan en `reports/locust/<ambiente>/<perfil>/`: `report.html` y los CSV (`stats_stats.csv` y `stats_stats_history.csv`).

## Cuidados

- Corre solo contra dev o stage, nunca contra prod. `SurveyUser` crea cuestionarios con IDs anónimos nuevos y sin síntomas, así que no cerca a nadie, pero sí deja datos de prueba (marcados con `"source": "locust-us27"`).
- Mientras corre la prueba, el dashboard de Grafana de US-24 muestra cómo responde cada servicio. Para el análisis conviene cruzar el p95 de Locust con el p95 por servicio.

## Resultados

La corrida contra dev del 24 de noviembre (versión 0.4.0) y su análisis están en [`docs/operaciones/RENDIMIENTO_LOCUST_US27.md`](../../docs/operaciones/RENDIMIENTO_LOCUST_US27.md). Resumen: la carga esperada cumple los umbrales y el punto de quiebre es el login de auth-service, por el pool de conexiones a PostgreSQL.
