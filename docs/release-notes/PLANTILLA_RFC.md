# Solicitud de cambio formal (Request For Change - RFC)

## 1. Informacion general

- **Codigo RFC:** `RFC-YYYYMMDD-001`
- **Historia de usuario / Jira:** `[US-XX]` / `[SCRUM-YY]`
- **Autor / Solicitante:** 
- **Fecha de solicitud:** YYYY-MM-DD
- **Tipo de cambio:** [ ] Estandar  |  [ ] Normal  |  [ ] Emergencia / Hotfix
- **Servicios afectados:** 
  - [ ] auth-service (8180)
  - [ ] identity-service (8083)
  - [ ] promotion-service (8082)
  - [ ] form-service (8085)
  - [ ] gateway-service (8084)
  - [ ] notification-service (8086)
  - [ ] file-service (8087)
  - [ ] dashboard-service (8088)
  - [ ] mobile (8080)
  - [ ] infraestructura / CI-CD / Docker

## 2. Descripcion y justificacion tecnica

- **Motivo del cambio:** Breve explicacion del problema de negocio o requerimiento funcional que origina la modificacion.
- **Detalle de la implementacion:** Resumen de las modificaciones aplicadas en codigo, esquemas de bases de datos o configuraciones de despliegue.
- **Impacto en SemVer:** [ ] MAJOR (cambio incompatible) | [ ] MINOR (funcionalidad) | [ ] PATCH (correccion)
- **Version estimada resultante:** `vX.Y.Z`

## 3. Analisis de riesgos e impacto operativo

| Factor de riesgo | Nivel (Bajo / Medio / Alto) | Medida de mitigacion |
| :--- | :---: | :--- |
| Indisponibilidad del servicio | | Despliegue con transicion suave mediante comprobaciones de salud activas. |
| Corrupcion o perdida de datos | | Copia de respaldo previa de bases de datos relacionales y de grafos. |
| Incompatibilidad de APIs externas | | Validacion de contratos REST y esquemas de serializacion de Kafka. |
| Sobrecarga de recursos computacionales | | Limites estrictos de memoria y CPU configurados en compose de produccion. |

## 4. Plan de pruebas y validacion

1. **Pruebas unitarias:** Validacion local con `./gradlew test jacocoTestReport` superando el 60% de cobertura.
2. **Pruebas estaticas:** Quality Gate de SonarQube verificado en verde.
3. **Pruebas en pre-produccion (stage):** Ejecucion de la suite de pruebas E2E con Playwright.
4. **Comprobacion post-despliegue (Smoke Test):** Consultas directas a endpoints `/actuator/health/liveness` y flujo de autenticacion basico.

## 5. Plan de rollback (Contingencia)

En caso de degradacion del servicio o deteccion de fallos no mitigables en produccion:

1. **Version anterior verificada:** `vX.Y.(Z-1)`
2. **Procedimiento de regreso:**
   ```bash
   cd /opt/circleguard/prod/compose
   sed -i 's/IMAGE_TAG=.*/IMAGE_TAG=vX.Y.(Z-1)/' /opt/circleguard/prod/.env
   docker compose -f docker-compose.prod.yml up -d
   ```
3. **Tiempo maximo de recuperacion objetivo (RTO):** Menor a 5 minutos.
4. **Criterio de activacion del rollback:** Caida de liveness check durante mas de 60 segundos tras el arranque.

## 6. Registro de aprobaciones

- **Revisor par (Peer Review):** [Aprobado / Pendiente] - Firma / Usuario:
- **DevOps / Platform Lead:** [Aprobado / Pendiente] - Firma / Usuario:
- **Fecha y hora de autorizacion:** YYYY-MM-DD HH:MM UTC
