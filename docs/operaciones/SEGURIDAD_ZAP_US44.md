# Análisis dinámico con OWASP ZAP baseline (US-44)

Historia US-44 (SCRUM-127). Responsable: Esteban Cuéllar.

ZAP baseline revisa la aplicación **desplegada**: recorre el sitio con la araña y aplica solo reglas **pasivas** (cabeceras de seguridad, cookies, divulgación de información, etc.). No lanza ataques, así que es seguro correrlo contra dev o stage en cada versión.

| Pieza | Archivo |
| :--- | :--- |
| Script | `infra/scripts/zap-scan.sh` |
| Reglas y excepciones | `.zap/baseline-rules.tsv` |
| Pruebas del script | `infra/scripts/test-platform-scripts.sh` (sección US-44) |
| Etapa de Jenkins | `ZAP Baseline against dev` (parte 2 de la historia) |

## 1. Qué se escanea

| Objetivo | Servicio | Puerto en dev | Puerto en stage |
| :--- | :--- | :--- | :--- |
| `web` | cliente web (Nginx + Expo web) | 8080 | 9080 |
| `auth` | API de auth-service | 8180 | 9180 |
| `gateway` | validación del QR (gateway-service) | 8087 | 9087 |

Los puertos son los que publica `deploy/compose/docker-compose.<env>.yml`. El script llega a ellos igual que `deploy/scripts/run-e2e.sh`:

- `--host <ip>`: túnel SSH hacia el nodo del ambiente. Es lo que usa Jenkins con compose.
- `--k8s`: `kubectl port-forward` a los Services del namespace `circleguard-<env>` (US-39).
- `--local`: los puertos publicados por la pila local (`KEEP_UP=1 bash deploy/compose/smoke-up.sh dev`).

**prod se rechaza:** la araña genera tráfico y peticiones de prueba.

ZAP corre en Docker, con la imagen `zaproxy/zap-stable:2.17.0` fijada por versión, igual que Trivy. En Jenkins, el contenedor de ZAP comparte la red del contenedor del agente, así ve los túneles en `127.0.0.1`. Los reportes salen con `docker cp`, porque las rutas del workspace de Jenkins no existen en el host de Docker.

## 2. Política y umbral (CA2)

| Riesgo de la alerta | Qué pasa |
| :--- | :--- |
| **Alto** | Cuenta contra el umbral `ZAP_MAX_HIGH` (por defecto **0**). Si lo supera, el script sale con **1**. |
| Medio | Se reporta y queda en el reporte, sin fallar. |
| Bajo / informativo | Se reporta, sin fallar. |

- Una regla marcada como `FAIL` en `.zap/baseline-rules.tsv` cuenta como alerta alta.
- Una regla `IGNORE` solo se agrega con su justificación, su responsable y una fecha de revisión, como las excepciones de Trivy en `.trivyignore`. Hoy no hay ninguna.
- **En el pipeline**, un resultado `1` deja la etapa en **UNSTABLE** y el build visible en amarillo, pero **no bloquea** la promoción a stage. Es la política acordada mientras se corrigen los primeros hallazgos. Para volverla bloqueante basta cambiar la etapa a `error()`; el script no cambia.

Códigos de salida: `0` dentro del umbral, `1` umbral superado, `2` uso inválido, `3` ZAP no pudo escanear algún objetivo.

## 3. Reportes (CA1)

En `reports/zap/<env>/`, archivados como artefactos de Jenkins:

| Archivo | Contenido |
| :--- | :--- |
| `<objetivo>.html` | Reporte de ZAP para leer |
| `<objetivo>.json` | Reporte completo (alertas, instancias, CWE, solución) |
| `<objetivo>.md` | Resumen en Markdown, útil para el informe consolidado |
| `junit/<objetivo>.xml` | Una prueba por objetivo: falla si tiene alertas de riesgo alto |
| `summary.json` | Alertas altas, medias y bajas por objetivo, y el resultado (`PASS`, `FAIL`, `ERROR`) |

## 4. Cómo correrlo

```bash
# Contra el nodo dev (llave SSH del ambiente)
SSH_KEY=~/.ssh/circleguard-dev.pem bash infra/scripts/zap-scan.sh --env dev --host 52.15.165.116

# Contra la pila local
KEEP_UP=1 bash deploy/compose/smoke-up.sh dev
bash infra/scripts/zap-scan.sh --env dev --local

# Ver los comandos sin ejecutar nada
DRY_RUN=1 bash infra/scripts/zap-scan.sh --env dev --host 52.15.165.116
```

Variables: `ZAP_MAX_HIGH`, `ZAP_TARGETS` (por defecto `web auth gateway`), `ZAP_MINUTES` (duración de la araña, 2), `ZAP_IMAGE`, `ZAP_DOCKER_NETWORK`, `REPORT_DIR`.
