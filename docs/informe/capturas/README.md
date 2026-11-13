# Capturas del informe de la Parte 1

El informe ([`../INFORME_PARTE1.md`](../INFORME_PARTE1.md)) enlaza cada figura de esta carpeta por su nombre. Mientras una captura falta, el informe muestra en su lugar un recuadro **«Captura pendiente»** con la instrucción para tomarla, así que nunca se entrega una figura vacía sin aviso.

Reglas:

- Formato PNG, de unos 1440 × 900 px, con la URL o el *breadcrumb* visible cuando sea posible.
- **Sin secretos.** No captures páginas de credenciales, `.env`, tokens ni la llave `.pem`. Revisa que la consola de Jenkins no muestre valores sensibles.
- Al agregar una captura pendiente, reemplaza su recuadro en `INFORME_PARTE1.md` por la imagen y márcala como «Incluida» en el anexo C.

## Automáticas (Jenkins y Nexus)

Las genera `node docs/informe/scripts/capture-evidence.mjs`. Jenkins exige sesión (US-31), así que el script necesita el API token de una cuenta; sirve la de solo lectura, `docente`. El token se crea en Jenkins, en *usuario → Security → API Token*:

```bash
read -rsp "API token de Jenkins: " JENKINS_API_TOKEN; export JENKINS_API_TOKEN
JENKINS_USER=docente MAIN_BUILD=18 node docs/informe/scripts/capture-evidence.mjs
unset JENKINS_API_TOKEN
```

`MAIN_BUILD=<n>` elige el build de `main`; por defecto toma el último exitoso. El token solo se envía a Jenkins.

| Archivo | Página |
|---|---|
| `e1-2-jenkins-dashboard.png` | Inicio de Jenkins |
| `e1-2-nexus-home.png` | Inicio de Nexus |
| `e1-3-nexus-docker-images.png` | Índice `circleguard-docker/v2/circleguard/` |
| `e1-3-nexus-auth-service-tags.png` | Tags de `auth-service` |
| `e1-4-jenkins-multibranch-branches.png` | Job Multibranch, pestaña Branches |
| `e1-4-jenkins-multibranch-prs.png` | Job Multibranch, pestaña Pull Requests |
| `e1-4-jenkins-main-job.png` | Job `main` con la Stage View |
| `e1-4-jenkins-main-build.png` | Build `MAIN_BUILD` de `main` |
| `e1-5-jenkins-main-console-semver.png` | Consola del build, en la línea del cálculo SemVer |
| `e1-6-jenkins-main-tests.png` | Resultados JUnit del build |
| `e1-6-jenkins-main-jacoco.png` | Reporte JaCoCo del build |
| `e1-6-jenkins-main-last-build.png` | Último build de `main` |

## Manuales (requieren sesión o una ejecución nueva)

| Archivo | Qué capturar | Responsable sugerido |
|---|---|---|
| `e1-1-jira-board.png` | Jira → SuperPoderosos → Backlog o tablero: historias, puntos y épicas | Quien administra Jira |
| `e1-1-github-branch-protection.png` | GitHub → Settings → Branches → regla de `main` | Dueño del repositorio |
| `e1-1-github-pull-requests.png` | GitHub → Pull requests → Closed, con revisores y checks | Cualquiera |
| `e1-1-github-pull-request-detail.png` | Detalle de un PR: trazabilidad con Jira, resumen y revisor | Cualquiera |
| `e1-2-aws-ec2-instances.png` | Consola de AWS → EC2 → Instances (us-east-2): las 4 instancias | Dueño de la cuenta de AWS |
| `e1-4-github-webhook.png` | GitHub → Settings → Webhooks → `/github-webhook/` → Recent Deliveries (200) | Dueño del repositorio |
| `e1-4-sonarqube-quality-gate.png` | SonarQube → *Projects → CircleGuard Monorepo*: panel del Quality Gate y cobertura | Responsable de US-10 |
| `e1-5-git-tags.png` | GitHub → Tags (`v0.1.x`) | Cualquiera |
| `e1-5-jenkins-main-cd-stages.png` | Stage View del build #18 de `main` con `Deploy to dev` → `Verify stage health` en verde | Cualquiera |
| `e1-5-discord-notification.png` | Discord → servidor **CircleGuard CI** → canal `#pipeline`: mensaje de un build (rama, commit, versión, etapa, log) | Quien administra el servidor de Discord |
| `e1-5-jenkins-prod-approval-stage.png` | *Pipeline Steps* del build con `Verify stage health` en verde y `Approve prod release` en espera | `jrubio` o `jpordonez` (aprobadores de `CG_PROD_APPROVERS`) |
| `e1-5-jenkins-prod-approval-input.png` | Build detenido en `Approve prod release` → *Paused for Input*, con decisión, versión y comentario | `jrubio` o `jpordonez` |
| `e1-5-jenkins-prod-approval-console.png` | Consola del build: `Approved by …` y la línea `[US-31] APPROVED` | `jrubio` o `jpordonez` |
| `e1-5-discord-prod-release.png` | Discord → `#pipeline`: mensaje del build con `PROD APPROVED` | Quien administra el servidor de Discord |
| `e1-6-playwright-report.png` | Artefacto `e2e/reports/html/index.html` de un build verde | Responsable de US-34 o US-17 |
