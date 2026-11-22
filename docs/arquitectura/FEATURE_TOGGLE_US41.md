# US-41 — Feature Toggles en el servicio de notificaciones

| | |
|---|---|
| Historia | US-41, patrón de diseño Feature Toggle |
| Alcance | `circleguard-notification-service`: encender o apagar cada canal (correo, SMS, push) sin cambiar código ni reconstruir la imagen |
| Código | [`config/FeatureToggleProperties.java`](../../services/circleguard-notification-service/src/main/java/com/circleguard/notification/config/FeatureToggleProperties.java), [`feature/`](../../services/circleguard-notification-service/src/main/java/com/circleguard/notification/feature/), [`NotificationDispatcher.java`](../../services/circleguard-notification-service/src/main/java/com/circleguard/notification/service/NotificationDispatcher.java) |

## 1. Qué es un feature toggle

Un *feature toggle* (o *feature flag*) es un interruptor que decide en tiempo de ejecución si un comportamiento está activo. El código de las dos ramas (encendido y apagado) ya está desplegado; lo que cambia es la configuración. Así se separa **desplegar** (poner código en un ambiente) de **liberar** (que los usuarios usen la funcionalidad).

Según Pete Hodgson (martinfowler.com), hay cuatro tipos:

| Tipo | Para qué | Vida útil | Quién lo cambia |
|---|---|---|---|
| **Release** | Ocultar algo a medio terminar mientras se integra a `main` | Días o semanas | Equipo de desarrollo |
| **Ops** | Apagar una parte del sistema cuando falla o cuesta demasiado (*kill switch*) | Meses o permanente | Operaciones |
| **Experiment** | Pruebas A/B: cada grupo de usuarios ve una variante | Lo que dure el experimento | Producto |
| **Permission** | Funcionalidad solo para ciertos usuarios (beta, premium, admin) | Larga | Producto / negocio |

## 2. Qué tipo implementa CircleGuard

Los toggles de US-41 son **ops toggles** (y sirven también como release toggles) **basados en configuración**:

- *Ops*: si el proveedor de SMS (Twilio) falla o se acaba el saldo, se apaga el canal SMS en ese ambiente y el resto sigue enviando. En dev o stage se puede apagar el canal para no enviar mensajes reales.
- *Release*: un canal nuevo puede entrar a `main` apagado y encenderse primero en dev, luego en stage y al final en prod.
- *Basado en configuración*: el valor sale de `application.yml` y de variables de ambiente. No hay servicio externo de flags.

## 3. Diseño

```
application.yml / variables de ambiente
        │  circleguard.features.*
        ▼
FeatureToggleProperties   (@ConfigurationProperties, Map<String, Boolean>)
        │
        ▼
FeatureToggleService      isEnabled(flag)  · snapshot()
        │                         │
        ▼                         ▼
NotificationDispatcher     FeaturesEndpoint  → GET /actuator/features
(solo envía por los canales encendidos)
```

| Clase | Responsabilidad |
|---|---|
| `FeatureToggleProperties` | Lee `circleguard.features.<flag>` en un mapa. `FeatureToggleConfig` la registra con `@EnableConfigurationProperties` |
| `FeatureFlags` | Nombres de los flags como constantes, para no escribir cadenas sueltas |
| `FeatureToggleService` | Única puerta de entrada: `isEnabled(flag)`. **Fail-safe**: un flag que no está configurado cuenta como apagado (y se registra un `warn` una sola vez), así un error de tipeo nunca enciende algo por accidente |
| `FeaturesEndpoint` | Endpoint de Actuator que muestra los flags vigentes |
| `NotificationDispatcher` | Pregunta por cada canal antes de generar el contenido y enviarlo. Si un canal está apagado, registra `Channel <flag> disabled by feature toggle, skipping`. Si todos están apagados, termina sin error |

El resto del servicio no sabe que existen los toggles: la decisión está en un solo punto (el dispatcher), lo que facilita quitarlos después.

## 4. Flags

| Flag | Variable de ambiente | Valor por defecto | Efecto al apagarlo |
|---|---|---|---|
| `email-notifications` | `FEATURE_EMAIL_NOTIFICATIONS` | `true` | No se genera ni se envía el correo |
| `sms-notifications` | `FEATURE_SMS_NOTIFICATIONS` | `true` | No se genera ni se envía el SMS |
| `push-notifications` | `FEATURE_PUSH_NOTIFICATIONS` | `true` | No se genera ni se envía la notificación push |

Los valores por defecto son `true`, así que sin configurar nada el servicio se comporta igual que antes de US-41.

## 5. Cómo cambiar un flag por ambiente

Se define la variable de ambiente del contenedor y se reinicia el servicio. No se cambia código ni se reconstruye la imagen.

Docker Compose:

```yaml
services:
  notification-service:
    environment:
      FEATURE_SMS_NOTIFICATIONS: "false"
```

Kubernetes (ConfigMap + `envFrom`):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: notification-features
data:
  FEATURE_SMS_NOTIFICATIONS: "false"
---
# en el Deployment del servicio
envFrom:
  - configMapRef:
      name: notification-features
```

Después de cambiar el ConfigMap: `kubectl rollout restart deployment/<notification-service>`.

## 6. Cómo verificar los flags vigentes

```bash
curl http://localhost:8082/actuator/features
```

```json
{"email-notifications":true,"push-notifications":true,"sms-notifications":false}
```

El endpoint es de solo lectura y está en `management.endpoints.web.exposure.include`.

## 7. Pruebas

| Prueba | Qué demuestra |
|---|---|
| `FeatureToggleServiceTest` | Flag encendido, apagado, desconocido → apagado, y `snapshot()` no se puede modificar |
| `NotificationDispatcherTest` | Todos encendidos → tres canales; SMS apagado → no se llama a `SmsService` ni se genera su contenido; todos apagados → ningún canal |
| `FeaturesEndpointTest` | El endpoint devuelve los flags del servicio |
| `FeatureToggleBindingTest` | `circleguard.features.sms-notifications=false` se convierte en `false` en el mapa |

```bash
./gradlew :services:circleguard-notification-service:test
```

## 8. Límites y siguientes pasos

- **Requiere reinicio**: al estar en la configuración, el valor se lee al arrancar. Para cambiarlo en caliente, el siguiente paso sería Spring Cloud Config (con `@RefreshScope`) o un servicio de flags como Unleash o OpenFeature, que además permiten toggles de experimento y de permiso por usuario.
- **Deuda técnica**: cada toggle agrega una rama al código. Un release toggle se borra cuando la funcionalidad queda estable en prod; un ops toggle se revisa periódicamente para ver si todavía hace falta.
- **Combinaciones**: con N flags hay 2^N combinaciones. Las pruebas cubren todos encendidos, uno apagado y todos apagados.
