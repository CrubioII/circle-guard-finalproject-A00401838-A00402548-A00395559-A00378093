## 🔗 Trazabilidad con Jira (Obligatorio)

- **ID de Historia de Usuario (`US-XX`):** `US-` <!-- Ej: US-02 -->
- **Clave de Incidencia / Subtarea en Jira (`SCRUM-XX`):** `SCRUM-` <!-- Ej: SCRUM-15, SCRUM-35, SCRUM-36, SCRUM-37 -->
- **Enlace directo en Jira:** [https://circleguard777.atlassian.net/browse/SCRUM-XX](https://circleguard777.atlassian.net/browse/SCRUM-XX)
- **Épica Asociada:** `EPIC-` <!-- Ej: EPIC-01 (E1.1) -->

---

## 📝 Resumen de los Cambios

<!-- Describe de forma clara y concisa qué problema resuelve este Pull Request, qué archivos o componentes modifica y por qué se realizó de esta manera. -->

- 
- 

---

## 🏷️ Verificación de Conventional Commits y SemVer (`US-02` / `US-12`)

Marca el tipo de cambio principal e indica el impacto esperado en el **Versionado Semántico (`MAJOR.MINOR.PATCH`)** al integrarse en `main`:

- [ ] `feat(<scope>): ...` — Nueva funcionalidad (**Incrementa `MINOR` → `0.X.0`**)
- [ ] `fix(<scope>): ...` / `perf(<scope>): ...` / `refactor(<scope>): ...` / `build(<scope>): ...` — Corrección o mejora interna (**Incrementa `PATCH` → `0.0.X`**)
- [ ] `feat(<scope>)!: ...` / Incluye pie `BREAKING CHANGE:` — Cambio incompatible de API/Contrato (**Incrementa `MAJOR` → `X.0.0`**)
- [ ] `docs(<scope>): ...` / `test(<scope>): ...` / `ci(<scope>): ...` / `chore(<scope>): ...` — Documentación, pruebas, pipeline o mantenimiento

**Formato del título del PR y commits verificado:**
```text
<tipo>(<alcance>): <descripción corta en imperativo y minúscula>
```

---

## 🧩 Componentes / Servicios Impactados

Marca los módulos del monorepo **CircleGuard** modificados en este PR (usado por `detectChangedServices` en Jenkins):

- [ ] `services/auth-service` (`:8180`)
- [ ] `services/identity-service` (`:8083`)
- [ ] `services/promotion-service` (`:8082`)
- [ ] `services/notification-service` (`:8086`)
- [ ] `services/form-service` (`:8085`)
- [ ] `services/file-service` (`:8087`)
- [ ] `services/gateway-service` (`:8084`)
- [ ] `services/dashboard-service`
- [ ] `mobile/` (Cliente Web / Expo React Native)
- [ ] `infra/` / `deploy/` / `jenkins/` / `Jenkinsfile` (Infraestructura y CI/CD)
- [ ] `docs/` / `.github/` (Documentación Ágil, Arquitectura o Gobernanza)

---

## 🧪 Evidencia de Pruebas y Calidad

Describe cómo se validaron estos cambios antes de solicitar la revisión:

- [ ] Compilación local exitosa (`./gradlew assemble` o `npm run build`)
- [ ] Pruebas unitarias y cobertura JaCoCo verificadas (`./gradlew test jacocoTestReport`)
- [ ] Pruebas de integración / Testcontainers ejecutadas (si aplica)
- [ ] Pruebas E2E con Playwright verificadas (si aplica)
- [ ] Scripts Bash / Dockerfiles validados en modo idempotente y con usuario no-root (si aplica)

**Salida de pruebas / Capturas / Evidencia:**
```text
# Pega aquí el resumen de ejecución o adjunta capturas si aplica
```

---

## ✅ Lista de Chequeo de Revisión por Pares (Peer Review Checklist)

Antes de aprobar e integrar este PR en `main`, tanto el **autor** como el **revisor** deben confirmar:

- [ ] **Rama de origen válida:** El PR proviene de una rama `feature/*`, `fix/*`, `hotfix/*`, `docs/*` o `chore/*` actualizada respecto a `main`.
- [ ] **Trazabilidad Jira completa:** El PR referencia explícitamente la historia `US-XX` y su clave `SCRUM-XX` en Jira.
- [ ] **Cumplimiento de Conventional Commits:** Tanto los commits como el título del PR cumplen el estándar `tipo(alcance): descripción` (`feat`, `fix`, `feat!`, etc.).
- [ ] **Seguridad y Secretos:** No se incluyen contraseñas, tokens, llaves privadas ni credenciales en texto plano; las imágenes Docker no usan el tag `:latest` ni corren como `root`.
- [ ] **Documentación y Diagramas:** Si se añadieron o actualizaron diagramas, se generaron en **Excalidraw** (`docs/agil/diagramas/` o equivalente) sin utilizar Mermaid.
- [ ] **Quality Gate y Revisiones:** El PR cuenta con al menos **1 aprobación de otro integrante** del equipo y los *status checks* del pipeline están en verde.
