# Resultados y análisis de las pruebas de carga con Locust (`US-27` / `SCRUM-96`)

Corrida del 24 de noviembre de 2026 contra **dev** con la versión **0.4.0** (nodo `circleguard-env-dev`, `m7i-flex.large`, 2 vCPU y 8 GiB, servicios en Docker Compose). El script, los escenarios y los umbrales están en [`performance/locust`](../../performance/locust/README.md).

## 1. Cómo se corrió

- Locust 2.47.0 desde un portátil, por un túnel SSH hacia el nodo (los mismos puertos que usan los E2E).
- Perfiles `smoke` (5 usuarios, 1 min), `load` (50 usuarios, 5 min) y `stress` (200 usuarios, 5 min), uno detrás de otro.
- Durante las corridas, Prometheus (US-24) recogía las métricas de cada servicio cada 15 s. Las cifras "del servidor" de este documento salen de `http_server_requests_seconds` en esa ventana.

Todas las peticiones medidas por Locust tienen un mínimo de unos 95 ms. Ese piso es la ida y vuelta del túnel desde Colombia hasta `us-east-2`, no tiempo de los servicios. Por eso cada tabla trae también el p95 medido dentro del servicio.

## 2. Resultados

| Perfil | Peticiones | Throughput medio | Pico | p95 global (Locust) | Error | Umbrales |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| smoke | 159 | 2,7 req/s | 3,3 req/s | 580 ms | 0 % | Puerta 360 ms > 300 ms (ver §3.1) |
| load | 8.159 | 27,2 req/s | 30,5 req/s | 640 ms | 0 % | **Cumple** |
| stress | 18.007 | 58,2 req/s | 73,2 req/s | 16.000 ms | 0,17 % | p95 > 2000 ms (falla) |

### Carga esperada (`load`, 50 usuarios)

| Endpoint | Peticiones | p95 Locust | p95 servidor |
| :--- | ---: | ---: | ---: |
| `POST /api/v1/auth/login` | 626 | 3.600 ms | 3.454 ms |
| `GET /api/v1/auth/qr/generate` | 2.991 | 250 ms | 31 ms |
| `POST /api/v1/gate/validate` | 2.991 | 250 ms | 15 ms |
| `GET /api/v1/health-status/stats` | 320 | 260 ms | 45 ms |
| `POST /api/v1/surveys` | 1.217 | 260 ms | 40 ms |

Uso de recursos en la ventana: auth-service llegó a 48 % de CPU del nodo; los demás servicios no pasaron de 6 %. El heap más alto fue el de promotion-service (167 MB).

### Estrés (`stress`, 200 usuarios)

| Endpoint | Peticiones | Fallos | p95 Locust | p95 servidor |
| :--- | ---: | ---: | ---: | ---: |
| `POST /api/v1/auth/login` | 1.185 | 30 (2,5 %) | 25.000 ms | 27.684 ms |
| `GET /api/v1/auth/qr/generate` | 5.372 | 0 | 240 ms | 41 ms |
| `POST /api/v1/gate/validate` | 5.372 | 0 | 210 ms | 8 ms |
| `GET /api/v1/health-status/stats` | 1.262 | 0 | 220 ms | 34 ms |
| `POST /api/v1/surveys` | 4.816 | 0 | 220 ms | 21 ms |

En estrés auth-service subió a 76 % de CPU y la CPU del nodo llegó a 100 %. Los 30 fallos son `401` del login.

## 3. Análisis

### 3.1 El camino de ingreso al campus aguanta

La validación del QR en la puerta, que es la operación con una persona esperando, tarda 15 ms en el servidor con carga esperada y 8 ms con estrés. Generar el QR, enviar el cuestionario y consultar estadísticas se quedan por debajo de 50 ms en ambos perfiles. El throughput de esas operaciones subió casi al doble entre `load` y `stress` (de 10 a 17 validaciones por segundo) sin que su latencia cambiara.

El umbral de la puerta que falló en `smoke` (360 ms contra 300 ms) es ruido: con 58 muestras el p95 es la tercera petición más lenta, y en el servidor esas peticiones tardaron lo mismo que en `load`. Con 2.991 muestras el p95 de Locust bajó a 250 ms.

### 3.2 El cuello de botella es el login

El login es lo único que se degrada, y se degrada en el servidor, no en la red:

- Con 50 usuarios su p95 ya es de 3,5 s (umbral de carga: 800 ms global). El p95 global cumple solo porque el login es el 8 % de las peticiones.
- Con 200 usuarios el p95 pasa de 27 s y aparecen `401`. El log de auth-service muestra la causa:

  ```
  HikariPool-1 - Connection is not available, request timed out after 30006ms.
  ```

  Las peticiones esperan 30 s una conexión a PostgreSQL que no llega, la autenticación falla y el servicio responde `401` en lugar de un `503`.

Por qué se acaban las conexiones (hipótesis a confirmar con trazas de US-25):

1. auth-service usa el pool por defecto de HikariCP: **10 conexiones**.
2. `spring.jpa.open-in-view` no está desactivado, así que cada petición toma una conexión al empezar y la suelta al terminar.
3. El usuario de la prueba (`staff_guard`) es local. `DualChainAuthenticationProvider` intenta primero el bind contra LDAP, que falla, y luego valida la contraseña con BCrypt, que consume CPU a propósito. Cada login retiene su conexión durante todo ese tiempo.
4. Con la CPU del nodo al 100 %, BCrypt tarda más, cada conexión dura más ocupada y la cola crece.

Un efecto secundario importante: en el pico, el indicador de salud `db` de auth-service tardó 14 s en responder. En Kubernetes (US-38) la readiness de auth incluye `db`, así que con esta carga el pod saldría del Service justo cuando más falta hace.

### 3.3 Recomendaciones

| # | Cambio | Efecto esperado |
| :--- | :--- | :--- |
| 1 | `spring.jpa.open-in-view: false` en auth-service | La conexión se usa solo durante la consulta, no durante el bind LDAP ni BCrypt |
| 2 | Intentar primero el proveedor local cuando el usuario existe en la base, o cachear el resultado negativo de LDAP | Quita un bind fallido por cada login de usuario local |
| 3 | Responder `503` cuando no hay conexión (hoy es `401`) | El cliente distingue "contraseña mala" de "servicio saturado" y puede reintentar |
| 4 | Pool de 20 conexiones y `connection-timeout` de 5 s | Falla rápido en vez de colgar 30 s |
| 5 | En Kubernetes, escalar auth-service (ya está en el HPA de US-38) y revisar que la readiness no dependa de un `db` saturado | Más capacidad sin sacar pods sanos del Service |

Las recomendaciones 1 a 4 son cambios de código o configuración que quedan como historias aparte; esta historia solo mide y analiza.

## 4. Conclusión

Con la carga esperada de hora pico (50 usuarios concurrentes, unas 27 peticiones por segundo), dev cumple los tres umbrales: p95 de 640 ms, p95 de la puerta de 250 ms medido desde fuera (15 ms en el servidor) y 0 % de error. El sistema llega a unas 58 peticiones por segundo sostenidas antes de romperse, y lo que se rompe es el login por el pool de conexiones de auth-service. El ingreso al campus, que es el flujo crítico, sigue respondiendo en milisegundos aun con el login saturado.

## 5. Evidencia

- Reportes de Locust (HTML y CSV): `reports/locust/dev/{smoke,load,stress}/` en la máquina que corrió la prueba (la carpeta `reports/` no se versiona). Para repetirlos: `bash performance/locust/run-load-test.sh <perfil> dev` con el túnel abierto.
- Consultas de Prometheus usadas para el p95 del servidor:

  ```promql
  histogram_quantile(0.95, sum by (application, uri, le)
    (rate(http_server_requests_seconds_bucket{environment="dev", uri=~"/api/.*"}[5m])))
  max_over_time(process_cpu_usage{environment="dev"}[5m])
  ```

- Dashboard de Grafana durante las corridas: ver las capturas de [US-24](OBSERVABILIDAD_METRICAS_US24.md).
