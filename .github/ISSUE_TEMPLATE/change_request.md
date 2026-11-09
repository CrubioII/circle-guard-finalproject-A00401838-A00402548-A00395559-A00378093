---
name: Solicitud de cambio formal (RFC)
about: Plantilla para documentar y auditar solicitudes de cambio hacia stage y prod (US-18)
title: "[RFC] "
labels: ["rfc", "change-management"]
assignees: ""
---

## 1. Informacion general
- **Historia de usuario / Jira:** [US-XX] / [SCRUM-YY]
- **Tipo de cambio:** Estandar / Normal / Emergencia
- **Servicios afectados:** auth, identity, promotion, form, gateway, mobile u otros
- **Version SemVer calculada:** `vX.Y.Z`

## 2. Descripcion y justificacion
Describa el objetivo del cambio y los componentes modificados.

## 3. Analisis de riesgos y mitigacion
- **Nivel de riesgo estimado:** Bajo / Medio / Alto
- **Medidas de contingencia:**

## 4. Plan de pruebas
- [ ] Pruebas unitarias ejecutadas con cobertura requerida.
- [ ] SonarQube Quality Gate en verde.
- [ ] Pruebas funcionales y E2E superadas en ambiente de stage.

## 5. Plan de rollback
Indique la version anterior estable y el comando o script de restauracion inmediata en caso de contingencia.

## 6. Aprobaciones requeridas
- [ ] Revision por pares completada en Pull Request.
- [ ] Aprobacion manual registrada en Jenkins antes del despliegue a produccion.
