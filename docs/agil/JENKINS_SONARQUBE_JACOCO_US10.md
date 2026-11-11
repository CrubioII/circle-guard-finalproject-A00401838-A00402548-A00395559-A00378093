# Compilación Gradle, cobertura JaCoCo y Quality Gate bloqueante en SonarQube (`US-10` / `SCRUM-22`)

> **Proyecto:** CircleGuard (Ingeniería de Software V, Universidad Icesi)  
> **Espacio en Jira:** `SuperPoderosos` (`circleguard777.atlassian.net`)  
> **Épica Asociada:** `EPIC-04` (`SCRUM-7`): Integración Continua (CI) con Jenkins y SonarQube (`E1.4`)  
> **Historia de Usuario:** `US-10` (`SCRUM-22`): Integración de compilación Gradle, cobertura JaCoCo y Quality Gate bloqueante en SonarQube (`5 SP`)  
> **Subtareas Cubiertas:** `SCRUM-59` (`2 SP`, plugins `jacoco` y `org.sonarqube` en `build.gradle.kts`), `SCRUM-58` (`1 SP`, token, webhook de retorno y Quality Gate >= 60% en SonarQube) y `SCRUM-60` (`2 SP`, etapa de análisis SonarQube y `waitForQualityGate(abortPipeline: true)` en Jenkins).

## 1. Alcance

Esta historia conecta el monorepo Gradle con JaCoCo y SonarQube dentro del pipeline Multibranch de Jenkins:

1. **Instrumentación en Gradle (`CA1`, `SCRUM-59`):** [build.gradle.kts](../../build.gradle.kts) aplica el plugin `jacoco` en los 8 subproyectos y el plugin `org.sonarqube` en la raíz, generando reportes XML (`build/reports/jacoco/test/jacocoTestReport.xml`) y HTML después de cada ejecución de pruebas.
2. **Publicación de cobertura y envío a SonarQube (`CA2`, `SCRUM-60`):** el [Jenkinsfile](../../Jenkinsfile) ejecuta `:services:<svc>:jacocoTestReport`, calcula la cobertura por servicio con [sonarQualityGate.groovy](../../jenkins/vars/sonarQualityGate.groovy) y corre `./gradlew sonar` dentro de `withSonarQubeEnv('SonarQube')`. El reporte JaCoCo se publica en Jenkins una sola vez, en `post { always }` (US-31 / US-32), así también queda disponible cuando el build falla.
3. **Quality Gate bloqueante (`CA3`, `SCRUM-58`, `SCRUM-60`):** el script [setup-sonarqube-quality-gate.sh](../../jenkins/ci/setup-sonarqube-quality-gate.sh) registra en SonarQube el Quality Gate `CircleGuard-Quality-Gate` (con cobertura mínima del 60%) y el webhook de retorno hacia `<JENKINS_URL>/sonarqube-webhook/`. En el pipeline, la etapa `Quality Gate` ejecuta `waitForQualityGate(abortPipeline: true)` y detiene la ejecución si SonarQube devuelve un estado distinto de `OK` o si algún servicio núcleo queda por debajo del 60%.

### Integración con `main` (resolución de conflictos)

- **Orden de las etapas:** `SonarQube Analysis` y `Quality Gate` corren justo después de `Coverage Gate` y **antes** de `Publish Images to Nexus` y del despliegue a dev, stage y prod (US-13 / US-31). Un Quality Gate en rojo detiene el build antes de publicar o desplegar nada.
- **Carga del paso:** el Jenkinsfile usa `@Library('circleguard-shared-lib') _` sin fijar una rama, y carga `sonarQualityGate` desde el workspace (`load 'jenkins/vars/sonarQualityGate.groovy'`), igual que `notifyPipeline` en US-14. Así cada rama o PR prueba su propia versión del paso, y `main` nunca depende de una rama de feature.
- **Desactivar el análisis:** el parámetro `ENABLE_SONARQUBE_GATE=false` omite las dos etapas, por ejemplo si SonarQube no está disponible.

## 2. Criterios de aceptación y evidencia

| CA | Criterio | Implementación y validación |
| :---: | :--- | :--- |
| **CA1** | `build.gradle.kts` integra `jacoco` y `org.sonarqube` para generar reportes XML (`jacocoTestReport`) en los 8 microservicios. | [build.gradle.kts](../../build.gradle.kts) aplica `jacoco` en `subprojects`, vincula `test.finalizedBy(jacocoTestReport)`, activa `xml.required = true` y configura `sonar.coverage.jacoco.xmlReportPaths`. Validado en los Casos 1 al 4 de [validateSonarQualityGate.groovy](../../jenkins/test/validateSonarQualityGate.groovy). |
| **CA2** | El pipeline ejecuta compilación y pruebas, publica los reportes JaCoCo en Jenkins y envía las métricas a SonarQube. | [Jenkinsfile](../../Jenkinsfile) invoca `buildGradleCommandForServices(..., [includeJacoco: true])`, calcula `sonarQualityGate.collectServiceCoverage` (publica JaCoCo en `post { always }`), archiva `services/*/build/reports/jacoco/test/**` y ejecuta `SonarQube Analysis` con `withSonarQubeEnv('SonarQube')`. Validado en los Casos 3, 5, 6 y 10. |
| **CA3** | SonarQube evalúa un Quality Gate con cobertura >= 60% en los servicios núcleo y `waitForQualityGate(abortPipeline: true)` bloquea el pipeline ante fallo. | [setup-sonarqube-quality-gate.sh](../../jenkins/ci/setup-sonarqube-quality-gate.sh) crea el Quality Gate (>= 60%) y el webhook `/sonarqube-webhook/`. [sonarQualityGate.groovy](../../jenkins/vars/sonarQualityGate.groovy) ejecuta `waitForQualityGate(abortPipeline: true)` y verifica los 5 servicios núcleo (`auth`, `identity`, `promotion`, `form`, `gateway`). Validado en los Casos 7, 8, 9, 11 y 12. |

## 3. Servicios núcleo y umbral de cobertura

Los 8 microservicios generan reportes XML y HTML de JaCoCo. El umbral bloqueante de cobertura mínima (`>= 60%`) aplica sobre los 5 microservicios núcleo del sistema:

- `circleguard-auth-service`
- `circleguard-identity-service`
- `circleguard-promotion-service`
- `circleguard-form-service`
- `circleguard-gateway-service`

Los 3 servicios complementarios (`circleguard-notification-service`, `circleguard-file-service` y `circleguard-dashboard-service`) también publican sus reportes XML en Jenkins y SonarQube.

## 4. Archivos implementados

| Archivo | Función |
| :--- | :--- |
| [build.gradle.kts](../../build.gradle.kts) | Configuración de `jacoco` (`0.8.12`), `org.sonarqube` (`5.1.0.4882`), `jacocoTestReport` (XML/HTML), `jacocoTestCoverageVerification` (0.60 en servicios núcleo) y tarea `validateJenkinsSonarQualityGate`. |
| [Jenkinsfile](../../Jenkinsfile) | Habilita JaCoCo en `Compile & Test Backend`, añade las etapas `SonarQube Analysis` y `Quality Gate`, y archiva los reportes de cobertura. |
| [jenkins/vars/sonarQualityGate.groovy](../../jenkins/vars/sonarQualityGate.groovy) | Paso de la Shared Library para construir el comando de SonarQube, leer XML de JaCoCo, publicar cobertura en Jenkins y ejecutar `waitForQualityGate(abortPipeline: true)`. |
| [jenkins/vars/sonarQualityGate.txt](../../jenkins/vars/sonarQualityGate.txt) | Ayuda global de Jenkins para `sonarQualityGate`. |
| [jenkins/vars/multibranchFlow.groovy](../../jenkins/vars/multibranchFlow.groovy) | Incluye `SonarQube Analysis` y `Quality Gate` en el plan cuando hay cambios de backend. |
| [jenkins/ci/jenkins.yaml](../../jenkins/ci/jenkins.yaml) | Añade `sonarGlobalConfiguration` con la instalación `SonarQube` y la credencial `sonar-token`. |
| [jenkins/ci/setup-sonarqube-quality-gate.sh](../../jenkins/ci/setup-sonarqube-quality-gate.sh) | Script idempotente para crear el proyecto, el Quality Gate (>= 60%) y el webhook `/sonarqube-webhook/` en SonarQube. |
| [jenkins/test/validateSonarQualityGate.groovy](../../jenkins/test/validateSonarQualityGate.groovy) | Suite de 12 casos que comprueba `CA1`, `CA2` y `CA3` sin depender de un servidor externo. |
| [jenkins/test/validateSonarWebhookScript.sh](../../jenkins/test/validateSonarWebhookScript.sh) | Prueba del script de SonarQube con `--dry-run`, secreto enmascarado y `curl` simulado. |
| [jenkins/test/run-sonarqube-validation.sh](../../jenkins/test/run-sonarqube-validation.sh) | Ejecutor de la suite con Java + Groovy. |

## 5. Configuración operativa de SonarQube y Jenkins (`SCRUM-58`)

### 5.1 Credencial en Jenkins

En *Manage Jenkins -> Credentials -> System -> Global credentials*, crea una credencial de tipo **Secret text** con ID `sonar-token` y el token generado en SonarQube (*My Account -> Security -> Generate Tokens*). JCasC la enlaza automáticamente en `unclassified.sonarGlobalConfiguration`.

### 5.2 Configurar Quality Gate y webhook en SonarQube

```bash
export SONAR_HOST_URL="http://localhost:9000"
export SONAR_TOKEN="squ_..."
export JENKINS_URL="http://3.145.182.10:8080"
export SONAR_WEBHOOK_SECRET="$(openssl rand -hex 24)"

# Revisar el plan sin modificar SonarQube:
./jenkins/ci/setup-sonarqube-quality-gate.sh --dry-run

# Aplicar configuración idempotente:
./jenkins/ci/setup-sonarqube-quality-gate.sh
```

## 6. Validación reproducible

```bash
# Generar reporte XML de JaCoCo en un microservicio:
./gradlew :services:circleguard-auth-service:test :services:circleguard-auth-service:jacocoTestReport

# Ejecutar la suite de validación de US-10:
./jenkins/test/run-sonarqube-validation.sh

# O ejecutar las 3 suites de CI desde Gradle:
./gradlew validateJenkinsSharedLibrary validateJenkinsMultibranchPipeline validateJenkinsSonarQualityGate
```

## 7. Trazabilidad Jira

| Elemento | Referencia |
| :--- | :--- |
| Historia de Usuario | [US-10 / SCRUM-22](https://circleguard777.atlassian.net/browse/SCRUM-22) |
| Subtarea SonarQube y webhook | [SCRUM-58](https://circleguard777.atlassian.net/browse/SCRUM-58) |
| Subtarea Gradle + JaCoCo + SonarQube | [SCRUM-59](https://circleguard777.atlassian.net/browse/SCRUM-59) |
| Subtarea Jenkinsfile + waitForQualityGate | [SCRUM-60](https://circleguard777.atlassian.net/browse/SCRUM-60) |
| Épica | [EPIC-04 / SCRUM-7](https://circleguard777.atlassian.net/browse/SCRUM-7) |
