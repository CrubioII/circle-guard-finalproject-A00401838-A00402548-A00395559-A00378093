# Informe consolidado de calidad y pruebas (`US-44` / `SCRUM-127`, parte 3)

Este informe reúne en un solo lugar el análisis estático (SonarQube), las pruebas E2E (Playwright), las pruebas de carga (Locust) y el análisis dinámico de seguridad (OWASP ZAP baseline) de la versión **0.4.0** desplegada en **dev**.

| Fuente | Fecha | Alcance |
| :--- | :--- | :--- |
| SonarQube 10.6, proyecto `circleguard-monorepo` | análisis de `main` del 26 nov 2026, 06:50 UTC | 8 microservicios Java/Kotlin, 4.261 líneas de código |
| Playwright (`deploy/scripts/run-e2e.sh --host`) | 24 nov 2026 | dev 0.4.0, Docker Compose |
| Locust (`performance/locust`) | 24 nov 2026, 21:43 a 22:01 UTC | dev 0.4.0, perfiles `smoke`, `load` y `stress` |
| ZAP baseline (`infra/scripts/zap-scan.sh`) | 24 nov 2026 | dev 0.4.0: `web`, `auth` y `gateway` |

## 1. Resumen

| Prueba | Resultado | Umbral | Estado |
| :--- | :--- | :--- | :--- |
| Quality gate de Sonar | `OK`, las 7 condiciones | gate del proyecto (§2) | Cumple |
| Cobertura total | 83,9 % (líneas 94,7 %, ramas 51,6 %) | ≥ 60 % | Cumple |
| Cobertura del código nuevo | 94,0 % | ≥ 60 % | Cumple |
| E2E contra dev | 20 pasan, 3 omitidas, 0 fallan | 0 fallos | Cumple |
| Locust `load` (50 usuarios) | p95 640 ms, 27,2 req/s, 0 % error | p95 ≤ 800 ms, error ≤ 1 % | Cumple |
| Locust `stress` (200 usuarios) | p95 16 s, 58,2 req/s, 0,17 % error | p95 ≤ 2.000 ms | Falla (login, §4) |
| ZAP baseline | 0 altas, 1 media, 6 bajas | 0 altas (`ZAP_MAX_HIGH`) | Cumple |

Con la carga esperada la versión cumple todos los umbrales. Hay tres deudas abiertas: el login se satura por encima de unos 58 req/s, Sonar marca 11 bugs viejos (2 de ellos `BLOCKER`) que el gate no ve porque solo evalúa el código nuevo, y hay 16 security hotspots sin revisar.

## 2. Análisis estático (SonarQube)

### Quality gate

El gate evalúa el código nuevo desde la versión anterior (21 nov 2026) y la cobertura total:

| Condición | Umbral | Valor | Estado |
| :--- | :--- | ---: | :--- |
| Confiabilidad del código nuevo | rating A | A | OK |
| Seguridad del código nuevo | rating A | A | OK |
| Mantenibilidad del código nuevo | rating A | A | OK |
| Cobertura del código nuevo | ≥ 60 % | 94,0 % | OK |
| Cobertura total | ≥ 60 % | 83,9 % | OK |
| Duplicación del código nuevo | ≤ 3 % | 0,0 % | OK |
| Issues nuevos | 0 | 0 | OK |

### Métricas del proyecto completo

| Métrica | Valor | Rating |
| :--- | ---: | :--- |
| Bugs | 11 | E |
| Vulnerabilidades | 0 | A |
| Security hotspots sin revisar | 16 | E (revisión) |
| Code smells | 116 (deuda de 14,5 h) | A |
| Duplicación | 2,5 % | |
| Pruebas unitarias | 235 | |

Los ratings E de confiabilidad y de revisión de seguridad son del código anterior al período del gate. Por eso el gate pasa. No hay que leerlo como "sin bugs".

### Cobertura por servicio

| Servicio | Líneas de código | Cobertura | Líneas | Ramas | Bugs | Code smells |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| gateway-service | 101 | 100,0 % | 100,0 % | 100,0 % | 0 | 9 |
| auth-service | 540 | 97,9 % | 98,3 % | 93,8 % | 0 | 25 |
| dashboard-service | 220 | 96,9 % | 98,9 % | 92,5 % | 0 | 8 |
| file-service | 58 | 87,5 % | 87,5 % | sin ramas | 0 | 4 |
| notification-service | 592 | 87,5 % | 91,6 % | 72,4 % | 8 | 14 |
| promotion-service | 2.020 | 85,7 % | 94,9 % | 56,1 % | 3 | 39 |
| form-service | 418 | 81,8 % | 92,0 % | 55,9 % | 0 | 6 |
| identity-service | 312 | 44,0 % | 91,8 % | 5,7 % | 0 | 11 |

identity-service es el único servicio por debajo del 60 %. Las pruebas pasan por casi todas sus líneas, pero solo por el 5,7 % de sus ramas: faltan los casos de error y los caminos alternativos.

### Bugs abiertos

| Severidad | Regla | Dónde | Qué pasa |
| :--- | :--- | :--- | :--- |
| BLOCKER ×2 | `java:S2229` | promotion-service, `HealthStatusService` (líneas 38 y 190) | Un método llama a otro de la misma clase que pide otra propagación de `@Transactional`. La llamada no pasa por el proxy de Spring y la transacción del método llamado se ignora. |
| CRITICAL | `java:S2119` | promotion-service, `CircleService:91` | Se crea un `Random` nuevo en cada llamada |
| MAJOR ×8 | `java:S6857` | notification-service: `LmsServiceImpl`, `PushServiceImpl`, `TemplateService`, `PriorityAlertListener`, `RoomReservationServiceImpl` | Placeholders `@Value` mal formados |

Los dos `BLOCKER` son los primeros que hay que corregir: afectan el cambio de estado de salud, que es el núcleo del dominio.

### Security hotspots

| Prob. | Categoría | Cantidad | Dónde |
| :--- | :--- | ---: | :--- |
| Alta | CSRF desactivado | 3 | `SecurityConfig` de auth, identity y promotion |
| Alta | SQL dinámico | 1 | dashboard-service, `AnalyticsService` |
| Media | Regex con backtracking (DoS) | 1 | auth-service, `IdentityClient` |
| Media | PRNG no criptográfico | 2 | dashboard `AnalyticsService`, promotion `CircleService` |
| Baja | CORS habilitado | 7 | controladores de dashboard, file, form y promotion |
| Baja | Función de depuración | 1 | auth-service, `LoginController` |
| Baja | Carpeta con escritura pública | 1 | form-service, `StorageService` |

El CSRF desactivado es esperable en APIs sin estado con JWT en la cabecera `Authorization`; hay que marcarlo como revisado en Sonar con esa justificación. El SQL dinámico de dashboard-service sí hay que revisarlo línea por línea antes de cerrar el hotspot.

## 3. Pruebas E2E (Playwright)

Corrida con `bash deploy/scripts/run-e2e.sh --host <ip-dev>` contra dev 0.4.0:

| Suite | Pruebas | Pasan | Omitidas | Fallan |
| :--- | ---: | ---: | ---: | ---: |
| `deployed/health.spec.ts` | 6 | 6 | 0 | 0 |
| `deployed/auth-identity.spec.ts` | 4 | 4 | 0 | 0 |
| `deployed/gate-qr.spec.ts` | 4 | 4 | 0 | 0 |
| `deployed/web-client.spec.ts` | 2 | 2 | 0 | 0 |
| `smoke/app-shell.spec.ts` | 2 | 2 | 0 | 0 |
| `flows/access-validation.spec.ts` | 2 | 1 | 1 | 0 |
| `flows/login.spec.ts` | 2 | 1 | 1 | 0 |
| `flows/health-questionnaire.spec.ts` | 1 | 0 | 1 | 0 |
| **Total** | **23** | **20** | **3** | **0** |

Las 3 omitidas solo corren con la API simulada (modo mock) y se saltan a propósito contra un ambiente real. Duración total: 12,8 s.

## 4. Rendimiento (Locust)

El análisis completo está en [`RENDIMIENTO_LOCUST_US27.md`](RENDIMIENTO_LOCUST_US27.md). Lo esencial:

| Perfil | Peticiones | Throughput | p95 global | Error | Umbrales |
| :--- | ---: | ---: | ---: | ---: | :--- |
| smoke (5 usuarios) | 159 | 2,7 req/s | 580 ms | 0 % | Puerta 360 ms > 300 ms (ruido con 58 muestras) |
| load (50 usuarios) | 8.159 | 27,2 req/s | 640 ms | 0 % | Cumple |
| stress (200 usuarios) | 18.007 | 58,2 req/s | 16.000 ms | 0,17 % | Falla |

- La validación del QR en la puerta tarda 15 ms en el servidor con carga esperada y 8 ms en estrés.
- El login es el cuello de botella: p95 de 3,5 s con 50 usuarios y de 27,7 s con 200, con 30 respuestas `401`. auth-service agota el pool de HikariCP (`Connection is not available, request timed out after 30006ms`).
- Las cifras de Locust incluyen unos 95 ms de túnel SSH desde Colombia hasta `us-east-2`.

## 5. Análisis dinámico (OWASP ZAP baseline)

`zaproxy/zap-stable:2.17.0`, araña de 2 minutos y solo reglas pasivas, con `.zap/baseline-rules.tsv` y `ZAP_MAX_HIGH=0`.

| Objetivo | Altas | Medias | Bajas | Resultado |
| :--- | ---: | ---: | ---: | :--- |
| `web` (Nginx + Expo web) | 0 | 1 | 6 | PASS |
| `auth` (auth-service) | 0 | 0 | 0 | PASS |
| `gateway` (gateway-service) | 0 | 0 | 0 | PASS |

Hallazgos del cliente web:

| Riesgo | Alerta | Instancias | Corrección |
| :--- | :--- | ---: | :--- |
| Medio | Content Security Policy (CSP) Header Not Set | 5 | Cabecera `Content-Security-Policy` en la configuración de Nginx del cliente |
| Bajo | Cross-Origin-Embedder-Policy Header Missing | | Cabeceras de aislamiento en Nginx |
| Bajo | Cross-Origin-Opener-Policy Header Missing | | Igual que la anterior |
| Bajo | Cross-Origin-Resource-Policy Header Missing | | Igual que la anterior |
| Bajo | Permissions Policy Header Not Set | | Cabecera `Permissions-Policy` en Nginx |
| Bajo | Dangerous JS Functions | | Revisar en el bundle de Expo; suele ser código de terceros |
| Bajo | Timestamp Disclosure - Unix | | Falso positivo habitual en bundles minificados |

auth y gateway solo dejaron alertas informativas.

### Corrección del script de ZAP

La primera corrida terminó en `ERROR` en los tres objetivos con `AccessDeniedException: /zap/wrk/gateway.html`. La imagen `zap-stable` no trae la carpeta `/zap/wrk`, así que Docker crea el volumen anónimo con dueño `root` y el usuario `zap` (uid 1000) no puede escribir los reportes. En Jenkins pasaría lo mismo, y la etapa `ZAP Baseline against dev` quedaría siempre en UNSTABLE por código `3`.

Este PR cambia `infra/scripts/zap-scan.sh` para copiar al contenedor una carpeta `wrk` empaquetada con dueño `1000:1000` (con las reglas adentro) usando `docker cp -a`, antes de arrancarlo. La prueba de `infra/scripts/test-platform-scripts.sh` revisa ahora el listado del tar y falla con el script anterior. Los resultados de la tabla son de la corrida con el script corregido.

## 6. Acciones recomendadas

| # | Acción | Fuente | Prioridad |
| :--- | :--- | :--- | :--- |
| 1 | Corregir las llamadas internas con `@Transactional` de `HealthStatusService` | Sonar, 2 `BLOCKER` | Alta |
| 2 | `open-in-view: false`, pool de 20 y `connection-timeout` de 5 s en auth-service; responder `503` cuando no hay conexión | Locust stress | Alta |
| 3 | Revisar el SQL dinámico de `AnalyticsService` y cerrar los hotspots de CSRF con su justificación | Sonar hotspots | Alta |
| 4 | Cabeceras CSP, COOP, COEP, CORP y `Permissions-Policy` en el Nginx del cliente web | ZAP | Media |
| 5 | Pruebas de los caminos de error de identity-service (ramas al 5,7 %) | Sonar cobertura | Media |
| 6 | Corregir los 8 placeholders `@Value` de notification-service | Sonar bugs | Media |

Cada acción queda como historia o subtarea aparte; esta historia solo consolida y reporta.

## 7. Evidencia

- Sonar: `http://<ci-server>:9000/dashboard?id=circleguard-monorepo` (pide sesión). Los números salen de `api/qualitygates/project_status`, `api/measures/component`, `api/measures/component_tree`, `api/issues/search` y `api/hotspots/search`.
- E2E: `e2e/reports/dev/` (HTML y `junit/results.xml`), y en Jenkins la pestaña **Tests** del build que despliega.
- Locust: `reports/locust/dev/{smoke,load,stress}/` y el análisis de [US-27](RENDIMIENTO_LOCUST_US27.md).
- ZAP: `reports/zap/dev/` (`<objetivo>.html`, `.json`, `.md`, `summary.json` y `junit/`), y en Jenkins el reporte HTML **OWASP ZAP (dev)**.

La carpeta `reports/` no se versiona. Cada comando de la sección 4 de [SEGURIDAD_ZAP_US44.md](SEGURIDAD_ZAP_US44.md) y de [`performance/locust`](../../performance/locust/README.md) regenera su parte.
