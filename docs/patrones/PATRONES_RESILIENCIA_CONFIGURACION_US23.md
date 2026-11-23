# Patrones de resiliencia y configuración externa (US-23)

Historia US-23 (SCRUM-92), épica EPIC-12 (patrones de diseño, entregable E2.4). Responsable: Esteban Cuéllar.

Este documento cubre los dos patrones nuevos que US-23 agrega a CircleGuard: **Circuit Breaker + Retry con Resilience4j** y **External Configuration**. Los patrones que el sistema ya traía están en [PATRONES_EXISTENTES.md](PATRONES_EXISTENTES.md).

| Patrón | Dónde | PR |
| :--- | :--- | :--- |
| Circuit Breaker + Retry (+ timeouts) | auth → identity, dashboard → promotion | #55, #56 |
| External Configuration | URLs, timeouts y umbrales por variables de entorno | #55, #56 |

## 1. Por qué estas dos llamadas

CircleGuard se comunica casi todo por Kafka (ver *Arquitectura dirigida por eventos* en el catálogo existente). Solo quedan dos llamadas HTTP síncronas entre servicios, y son las que pueden arrastrar una falla de un servicio a otro:

| Llamada | Quién la usa | Qué pasaba si el destino fallaba |
| :--- | :--- | :--- |
| auth-service → identity-service (`POST /api/v1/identities/map`) | El login: cada inicio de sesión pide el ID anónimo del usuario | Sin timeout, un identity lento dejaba colgados los hilos del login; si caía, el login respondía 500 |
| dashboard-service → promotion-service (`GET /api/v1/health-status/stats`) | El dashboard administrativo | Tenía un fallback manual, pero sin timeout cada petición esperaba a que la conexión se venciera |

Los reintentos y la DLQ de los consumidores de Kafka son otro caso y no se tocan aquí.

## 2. Circuit Breaker + Retry con Resilience4j

### Propósito

- **Timeout**: ninguna llamada espera más de lo configurado (connect 1 s, read 2 s).
- **Retry**: un fallo transitorio (un reinicio del pod, un timeout aislado) se recupera solo, sin que el usuario lo note.
- **Circuit Breaker**: si el servicio destino sigue fallando, se deja de llamarlo por un tiempo y se responde de inmediato. Así no se gastan hilos ni se le suma carga a un servicio que ya está caído.
- **Respuesta degradada**: auth responde **503** ("intente más tarde") en vez de 500; dashboard responde su **fallback** (`"error": "Service unavailable"`).

### Cómo está implementado

- Dependencia `io.github.resilience4j:resilience4j-spring-boot3:2.2.0` en `services/circleguard-auth-service/build.gradle.kts` y `services/circleguard-dashboard-service/build.gradle.kts`.
- `services/circleguard-auth-service/src/main/java/com/circleguard/auth/client/IdentityClient.java` e `services/circleguard-dashboard-service/src/main/java/com/circleguard/dashboard/client/PromotionClient.java` decoran la llamada con `Retry.decorateSupplier(retry, CircuitBreaker.decorateSupplier(circuitBreaker, llamada))`.
- Los `RetryRegistry` y `CircuitBreakerRegistry` los crea Spring Boot a partir de `application.yml` (instancias `identityService` y `promotionService`).
- `IdentityServiceUnavailableException` + `LoginController` convierten el fallo en 503.

**Orden de los decoradores.** El Retry va por fuera del Circuit Breaker. Cada intento cuenta para el breaker, y cuando el breaker se abre lanza `CallNotPermittedException`, que no está en la lista de reintentos. Así no se reintenta contra un servicio que el breaker ya dio por caído.

### Parámetros

Son los mismos en las dos instancias. Entre paréntesis va la variable de entorno que los cambia (prefijo `IDENTITY_` en auth y `PROMOTION_` en dashboard).

| Parámetro | Valor | Por qué |
| :--- | :--- | :--- |
| Timeout de conexión (`*_CONNECT_TIMEOUT`) | 1 s | Dentro de la red del clúster o del compose, conectar toma milisegundos; más de 1 s indica que el destino no está |
| Timeout de lectura (`*_READ_TIMEOUT`) | 2 s | Las dos operaciones son lecturas simples; el p95 normal está muy por debajo |
| Intentos (`*_RETRY_MAX_ATTEMPTS`) | 3 | El intento original y 2 reintentos |
| Espera entre intentos (`*_RETRY_WAIT`) | 200 ms, backoff exponencial x2 | 200 ms y luego 400 ms: le da tiempo a un pod que reinicia sin sumar más de ~0,6 s al login |
| Excepciones que se reintentan | `ResourceAccessException` (red, timeout) y `HttpServerErrorException` (5xx) | Un 4xx es un error del pedido: reintentarlo no cambia el resultado |
| Ventana del breaker (`*_CB_WINDOW`) | últimas 10 llamadas | Suficiente para el volumen de un campus sin reaccionar a un fallo aislado |
| Mínimo de llamadas (`*_CB_MIN_CALLS`) | 5 | No se abre por 1 o 2 fallos justo después de arrancar |
| Umbral de fallos (`*_CB_FAILURE_RATE`) | 50 % | La mitad de las llamadas fallando es una caída, no ruido |
| Tiempo abierto (`*_CB_OPEN_WAIT`) | 30 s | El tiempo típico que tarda un pod en reiniciar y pasar su readiness |
| Llamadas en half-open | 3 | Prueba el servicio con pocas llamadas antes de cerrar el breaker |

### Pruebas

| Prueba | Qué verifica |
| :--- | :--- |
| `IdentityClientResilienceTest.retriesTransientServerErrorAndSucceeds` | Un 5xx seguido de un 200 termina en éxito, con 2 llamadas |
| `IdentityClientResilienceTest.doesNotRetryClientErrors` | Un 4xx no se reintenta ni cuenta como fallo del breaker |
| `IdentityClientResilienceTest.givesUpAfterMaxAttemptsWithUnavailableException` | Tras 3 intentos fallidos se lanza `IdentityServiceUnavailableException` |
| `IdentityClientResilienceTest.opensCircuitAndStopsCallingIdentityService` | Con 4 fallos en la ventana el breaker se abre y la siguiente llamada no llega a identity |
| `AuthControllersUnitTest.login_identityUnavailable_returns503` | El login responde 503 cuando identity no está disponible |
| `PromotionClientResilienceTest` (3 pruebas) | Lo mismo para dashboard, que responde el fallback en lugar de lanzar el error |

```bash
./gradlew :services:circleguard-auth-service:test :services:circleguard-dashboard-service:test
```

### Observabilidad

Resilience4j publica sus métricas en `/actuator/prometheus` (US-24), con las etiquetas `application` y `environment`:

```bash
curl -s http://<auth>:8180/actuator/prometheus | grep -E 'resilience4j_circuitbreaker_state|resilience4j_retry_calls'
```

- `resilience4j_circuitbreaker_state{name="identityService",state="open"} 1` indica que el breaker está abierto.
- `resilience4j_retry_calls_total{kind="successful_with_retry"}` cuenta los fallos que el Retry recuperó.

### Trade-offs

- **Latencia en el peor caso.** Con identity caído pero sin breaker abierto todavía, un login puede tardar hasta unos 6,6 s (3 intentos de 2 s más las esperas) antes del 503. A cambio, un fallo transitorio no le llega al usuario. Cuando el breaker se abre, el 503 es inmediato.
- **Reintentar un POST.** `/identities/map` es idempotente: devuelve el mismo ID anónimo para la misma identidad, así que reintentarlo es seguro. Una llamada que no sea idempotente no debe usar esta configuración.
- **Estado por instancia.** Cada réplica de auth tiene su propio breaker. Con varias réplicas, cada una detecta la caída por su cuenta. Es aceptable porque el breaker solo protege a quien llama.
- **Fallback en dashboard.** El dashboard muestra "Service unavailable" en vez de cifras viejas. No se guardan en caché para no mostrar datos de salud desactualizados como si fueran actuales.
- **Una dependencia más** (Resilience4j), mantenida y con versión fija.

## 3. External Configuration

### Propósito

El mismo artefacto (la misma imagen en Nexus) corre en dev, stage y prod. Lo que cambia por ambiente, como URLs, timeouts y umbrales, se pasa por **variables de entorno** en lugar de recompilar o tener un `application.yml` por ambiente.

### Cómo está implementado

En `application.yml` cada valor es un placeholder con valor por defecto:

```yaml
identity:
  service:
    url: ${IDENTITY_SERVICE_URL:http://localhost:8083}
    read-timeout: ${IDENTITY_READ_TIMEOUT:2s}
resilience4j:
  circuitbreaker:
    instances:
      identityService:
        failure-rate-threshold: ${IDENTITY_CB_FAILURE_RATE:50}
```

| Variable (auth) | Variable (dashboard) | Valor por defecto |
| :--- | :--- | :--- |
| `IDENTITY_SERVICE_URL` | `PROMOTION_SERVICE_URL` | `http://localhost:8083` / `http://localhost:8088` |
| `IDENTITY_CONNECT_TIMEOUT` | `PROMOTION_CONNECT_TIMEOUT` | `1s` |
| `IDENTITY_READ_TIMEOUT` | `PROMOTION_READ_TIMEOUT` | `2s` |
| `IDENTITY_RETRY_MAX_ATTEMPTS` | `PROMOTION_RETRY_MAX_ATTEMPTS` | `3` |
| `IDENTITY_RETRY_WAIT` | `PROMOTION_RETRY_WAIT` | `200ms` |
| `IDENTITY_CB_WINDOW` | `PROMOTION_CB_WINDOW` | `10` |
| `IDENTITY_CB_MIN_CALLS` | `PROMOTION_CB_MIN_CALLS` | `5` |
| `IDENTITY_CB_FAILURE_RATE` | `PROMOTION_CB_FAILURE_RATE` | `50` |
| `IDENTITY_CB_OPEN_WAIT` | `PROMOTION_CB_OPEN_WAIT` | `30s` |

- **Docker Compose**: `deploy/compose/docker-compose.<env>.yml` ya pasa `IDENTITY_SERVICE_URL` a auth; los demás parámetros toman su valor por defecto a menos que se agreguen al bloque `environment` del ambiente.
- **Kubernetes**: las mismas variables van en el `env` del Deployment o en un ConfigMap por overlay (`deploy/k8s/overlays/<env>`).

Ejemplo: en stage, para que el breaker reaccione más rápido en una prueba de caos:

```yaml
environment:
  IDENTITY_CB_MIN_CALLS: "3"
  IDENTITY_CB_OPEN_WAIT: "10s"
```

### Prueba

Spring Boot resuelve los placeholders al arrancar. Las pruebas de resiliencia construyen los clientes con valores distintos a los del YAML (ventana de 4, espera de 1 ms) y comprueban que el comportamiento sigue esos valores. Para verlo en un ambiente:

```bash
curl -s http://<auth>:8180/actuator/prometheus | grep 'resilience4j_circuitbreaker_failure_rate'
```

### Trade-offs

- **Sin recarga en caliente.** Cambiar un valor requiere reiniciar el contenedor. Un Config Server o la recarga de ConfigMaps lo evitaría, pero suma otra pieza de infraestructura para un beneficio pequeño en este proyecto.
- **Valores por defecto en el código.** Si falta una variable, el servicio arranca igual con el valor por defecto. Eso es cómodo en local, pero un error de nombre en una variable pasa en silencio. Por eso los valores que sí cambian por ambiente (las URLs) se fijan siempre en los compose y overlays.
- **Secretos fuera de este patrón.** Contraseñas y tokens no van en estas variables sino en Secrets (Kubernetes) o en el archivo `.env` del ambiente, que no está en Git.
