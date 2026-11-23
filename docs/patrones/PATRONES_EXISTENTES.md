# Patrones de diseño existentes en CircleGuard (US-23)

Épica EPIC-12 (patrones de diseño, entregable E2.4). Responsable: Juan Camilo Rubio.

Este catálogo describe los patrones que CircleGuard ya traía antes de la Parte 2, cada uno con la ruta y la línea donde se ve en el código. Los patrones nuevos de la Parte 2 tienen su propio documento en esta carpeta: Circuit Breaker + Retry con Resilience4j y External Configuration en [PATRONES_RESILIENCIA_CONFIGURACION_US23.md](PATRONES_RESILIENCIA_CONFIGURACION_US23.md) (US-23), y el tercer patrón en el documento de US-40.

Las líneas corresponden a `main` en el commit `0ad81ee`.

## Resumen

| Patrón | Dónde | Problema que resuelve en CircleGuard |
| :--- | :--- | :--- |
| Database per service | `init-db.sql`, `application.yml` de cada servicio | Cada servicio cambia su esquema sin coordinarse con los demás |
| Arquitectura dirigida por eventos (Kafka) | form, promotion, notification, identity | El envío de un cuestionario no espera a que se recalculen contactos ni a que salga un correo |
| Punto de control de acceso (gateway-service) | `circleguard-gateway-service` | La validación del QR en la entrada del campus responde sin consultar a promotion ni a la base de grafos |
| Caché de estado en Redis y caché local | promotion (escribe), gateway (lee) | La validación del QR es una lectura de una clave en memoria |
| Máquina de estados de salud | `HealthStatusService`, `StatusLifecycleService` | Las transiciones de un usuario y de sus contactos siguen reglas fijas y con tiempo de cerco |

## 1. Database per service

Cada microservicio con datos relacionales tiene su propia base en el mismo servidor PostgreSQL. Ningún servicio lee tablas de otro: cuando dashboard necesita datos de promotion, los pide por HTTP.

Evidencia:

- `init-db.sql:2-6` crea `circleguard_auth`, `circleguard_identity`, `circleguard_promotion`, `circleguard_dashboard` y `circleguard_form`.
- `services/circleguard-auth-service/src/main/resources/application.yml:5`, `services/circleguard-identity-service/src/main/resources/application.yml:8`, `services/circleguard-promotion-service/src/main/resources/application.yml:5`, `services/circleguard-form-service/src/main/resources/application.yml:5` y `services/circleguard-dashboard-service/src/main/resources/application.yml:5` apuntan cada uno a su base.
- promotion guarda además el grafo de contactos en Neo4j (`services/circleguard-promotion-service/src/main/resources/application.yml:15-16`), que solo usa ese servicio.
- `services/circleguard-dashboard-service/src/main/java/com/circleguard/dashboard/client/PromotionClient.java:16` y `:22` consultan a promotion por REST en vez de leer su base.

Trade-offs: las bases comparten un servidor PostgreSQL, así que la separación es lógica y no de recursos; una caída del servidor afecta a los cinco servicios. Las consultas que cruzan servicios dependen de llamadas HTTP o de eventos, sin transacciones entre bases.

## 2. Arquitectura dirigida por eventos con Kafka

Los servicios publican hechos de negocio en tópicos de Kafka y otros servicios reaccionan. El emisor no conoce a los consumidores.

| Tópico | Publica | Consume |
| :--- | :--- | :--- |
| `survey.submitted` | form, `HealthSurveyService.java:52` | promotion, `SurveyListener.java:16` |
| `certificate.validated` | form, `HealthSurveyService.java:78` | promotion, `SurveyListener.java:33` |
| `promotion.status.changed` | promotion, `HealthStatusService.java:119` | notification, `ExposureNotificationListener.java:22` |
| `alert.priority` | promotion, `HealthStatusService.java:135` | notification, `PriorityAlertListener.java:27` |
| `circle.fenced` | promotion, `HealthStatusService.java:150` | notification, `CircleFencedListener.java:20` |
| `audit.identity.accessed` | identity, `IdentityVaultController.java:97` | (auditoría) |

Rutas completas: `services/circleguard-form-service/src/main/java/com/circleguard/form/service/HealthSurveyService.java`, `services/circleguard-promotion-service/src/main/java/com/circleguard/promotion/listener/SurveyListener.java`, `services/circleguard-promotion-service/src/main/java/com/circleguard/promotion/service/HealthStatusService.java`, `services/circleguard-notification-service/src/main/java/com/circleguard/notification/service/` e `services/circleguard-identity-service/src/main/java/com/circleguard/identity/controller/IdentityVaultController.java`.

La cadena `form → Kafka → promotion → notification` está cubierta por la prueba de integración de US-16 (`FormKafkaPromotionIntegrationTest`).

Trade-offs: la consistencia es eventual (el estado de un contacto cambia segundos después del cuestionario). Un mensaje que falla siempre al procesarse se reintenta sin fin porque no hay Dead Letter Topic; US-42 propone agregarlo en el consumidor de promotion. Depurar un flujo requiere seguir el mensaje entre servicios, que es lo que resuelve el trazado de US-25.

## 3. Punto de control de acceso (gateway-service)

`circleguard-gateway-service` no enruta tráfico hacia los demás servicios como un API Gateway clásico. Es el punto de entrada de los torniquetes del campus: recibe el QR, verifica la firma JWT y decide verde o rojo con el estado guardado en Redis, sin llamar a promotion.

Evidencia:

- `services/circleguard-gateway-service/src/main/java/com/circleguard/gateway/controller/GateController.java:10` y `:15` exponen `POST /api/v1/gate/validate`.
- `services/circleguard-gateway-service/src/main/java/com/circleguard/gateway/service/QrValidationService.java:24-28` valida la firma del token y `:35` lee `user:status:<id>` en Redis.

El cliente web llama directamente a auth, identity, form y promotion (ver los puertos en `deploy/compose`). Un API Gateway de enrutamiento con un solo punto de entrada llega en la Parte 2 con el Ingress de Kubernetes (US-37).

Trade-offs: la validación es rápida y sigue funcionando si promotion o Neo4j están caídos. A cambio, el gateway depende de que Redis tenga el estado al día.

Observación encontrada al hacer este catálogo: `QrValidationService.java:37` niega el acceso solo con los estados `CONTAGIED` y `POTENTIAL`, pero promotion escribe en Redis `CONFIRMED`, `SUSPECT`, `PROBABLE`, `ACTIVE` y `RECOVERED` (`HealthStatusService.java:69-70`, `:86` y `:98`). Con los nombres actuales ningún usuario recibe rojo en la entrada. Las pruebas del gateway usan los nombres viejos, por eso no lo detectan. Hay que alinear los nombres (por ejemplo, negar `CONFIRMED`, `SUSPECT` y `PROBABLE`) en una historia aparte.

## 4. Caché de estado (Redis) y caché local

El estado de salud se guarda en Neo4j, pero cada vez que cambia, promotion copia el nuevo valor en Redis bajo `user:status:<anonymousId>`. El gateway solo lee de Redis.

Evidencia:

- `services/circleguard-promotion-service/src/main/java/com/circleguard/promotion/service/HealthStatusService.java:27` define el prefijo de la clave; `:98` y `:105` acumulan el estado del usuario y de sus contactos; `:159` y `:164` los escriben en lote con `multiSet`.
- `services/circleguard-promotion-service/src/main/java/com/circleguard/promotion/service/StatusLifecycleService.java:73` y `:85` actualizan Redis cuando el job horario libera usuarios.
- Caché local en promotion (cache-aside con Caffeine): `config/CacheConfig.java:14` activa `@EnableCaching`; `HealthStatusService.java:173` (`@Cacheable`) lee el estado y `:39` y `:168` (`@CacheEvict`) lo invalidan al cambiar.

En Redis el patrón es de escritura: quien cambia el dato actualiza la caché en el mismo flujo, en lugar de llenarla al primer fallo de lectura. La caché local de promotion sí es cache-aside.

Trade-offs: si la escritura en Redis falla después de actualizar Neo4j, el gateway queda con un estado viejo hasta el siguiente cambio. Solo el paso a `RECOVERED` pone un TTL de 30 días a la clave (`HealthStatusService.java:283`); las demás claves de estado no expiran solas.

## 5. Máquina de estados de salud

Cada usuario tiene un estado en su nodo de Neo4j (`model/graph/UserNode.java:19-20`) y las transiciones siguen reglas fijas:

| Desde | Evento | Hacia | Dónde |
| :--- | :--- | :--- | :--- |
| `ACTIVE` | Cuestionario con síntomas | `SUSPECT` | `listener/SurveyListener.java:26` |
| contacto directo de un `CONFIRMED` | Propagación | `SUSPECT` | `HealthStatusService.java:69` |
| contacto directo de un `SUSPECT` | Propagación | `PROBABLE` | `HealthStatusService.java:70` |
| contacto de segundo nivel de un `CONFIRMED` | Propagación | `PROBABLE` | `HealthStatusService.java:85-86` |
| `SUSPECT` / `PROBABLE` | Vence el cerco obligatorio | `ACTIVE` | `StatusLifecycleService.java:33` y `:47-58` |
| `SUSPECT` / `PROBABLE` | Intento de volver a `ACTIVE` antes del cerco | rechazado salvo override de admin | `HealthStatusService.java:43-44` y `:285-297` |
| cualquiera | Alta médica | `RECOVERED` | `HealthStatusService.java:275` |

La propagación excluye a quien ya está `CONFIRMED` o `RECOVERED` (`HealthStatusService.java:67`). Cada transición publica `promotion.status.changed`, y un caso confirmado o un brote de más de 20 afectados publica `alert.priority` (`:126-135`).

Trade-offs: las reglas están en consultas Cypher dentro de `HealthStatusService`, no en una clase de estados explícita, así que agregar un estado obliga a revisar varias consultas. A favor, la propagación ocurre en una sola transacción de Neo4j.
