#!/usr/bin/env groovy
// =============================================================================
// Jenkinsfile raíz — CircleGuard Multibranch Pipeline
// Historia de Usuario: US-30 (SCRUM-113) — Jenkins Multibranch que consume la
// Shared Library delimitada en US-09 (SCRUM-21).
//
// Criterios de aceptación cubiertos:
//   CA1: Carga la Shared Library 'circleguard-shared-lib' y usa
//        detectChangedServices, pipelineUtils, multibranchFlow y publishBuildStatus.
//   CA2: Distingue ramas de Pull Requests (CHANGE_ID) de main; los PR solo
//        compilan/prueban/publican estado y NUNCA despliegan (ni a prod).
//   CA3: Publica estados PENDING/SUCCESS/FAILURE en GitHub para el contexto
//        'continuous-integration/jenkins/pr-head' o '.../main'; el job Multibranch
//        y el webhook se declaran en jenkins/ci/jenkins.yaml.
//
// US-34: etapa 'E2E Playwright' (headless) que publica reportes HTML y JUnit
//        y falla el build si falla cualquier flujo E2E (incluidos los de US-17).
//
// US-13 — Despliegue automático a dev y promoción a stage tras E2E:
//   CA1: Toda ejecución de main que publica imágenes despliega esa versión SemVer en
//        dev y verifica los healthchecks de servicios y middleware.
//   CA2: Los flujos E2E de US-17 (más los contratos @deployed) corren contra los servicios
//        REALES de dev; solo si pasan se promueve la MISMA versión a stage.
//   CA3: Si fallan el despliegue, los healthchecks o los E2E, stage no se toca y la
//        decisión queda en reports/ci/promotion-stage.json y en la descripción del build.
//
// US-31 — Aprobación manual y despliegue verificado a prod (vía A):
//   CA1: Tras verificar stage, el build de main espera un `input` restringido a
//        CG_PROD_APPROVERS (timeout CG_PROD_APPROVAL_TIMEOUT_MIN); sin aprobación, prod no se toca.
//   CA2: Quién aprobó/rechazó, la versión y el comentario/RFC quedan en
//        reports/ci/prod-approval.json, en la descripción del build y en el estado de GitHub.
//   CA3: Tras desplegar, los healthchecks de prod se publican como pruebas JUnit
//        (reports/ci/junit/health-prod.xml) y en reports/ci/health-prod.json.
//
// US-14 — Notificaciones del pipeline (CA1, SCRUM-70):
//   Al terminar, jenkins/vars/notifyPipeline.groovy publica en el canal #pipeline de Discord
//   (credencial Secret text 'discord-webhook') el resultado con rama, commit, autor, versión
//   SemVer, etapa fallida y enlace al log. Notifica fallos, abortos, inestables y
//   recuperaciones siempre, y los éxitos solo en main. Desactivable con NOTIFY_DISCORD=false.
//
// US-10 — Análisis estático y Quality Gate bloqueante en SonarQube (SCRUM-22):
//   CA1: Compile & Test Backend genera jacocoTestReport (XML) por servicio y calcula la
//        cobertura de líneas por servicio (reports/ci/jacoco-coverage.json).
//   CA2: 'SonarQube Analysis' envía código, pruebas y cobertura al servidor 'SonarQube'
//        (withSonarQubeEnv + credencial 'sonar-token').
//   CA3: 'Quality Gate' bloquea el pipeline con waitForQualityGate(abortPipeline: true) y exige
//        >= 60% de líneas en los servicios núcleo. Corre ANTES de publicar imágenes y desplegar.
//   Desactivable con ENABLE_SONARQUBE_GATE=false (p. ej. si SonarQube no está disponible).
//
// US-22 — Terraform en Jenkins: 'Terraform Plan' de dev, stage y prod en cada PR o build de
//   main que toque infra/terraform (plan archivado en reports/terraform/). En main, apply del plan
//   guardado en dev (antes de desplegar dev), en stage (tras E2E de dev) y en prod solo después de
//   la aprobación manual de US-31. Credencial 'aws-terraform' (usuario/clave de acceso), opcional:
//   si no existe, plan y apply se omiten con una advertencia. El apply en main además exige la
//   variable global CG_TERRAFORM_APPLY=true; sin ella main solo hace plan.
//
// US-38 — Trivy bloqueante: 'Trivy IaC Scan' (trivy config sobre infra/terraform y deploy/k8s) en
//   todo build pesado y 'Trivy Image Scan' sobre las 9 imágenes entre 'Build Images' y
//   'Publish Images to Nexus'. HIGH/CRITICAL con --exit-code 1; excepciones en .trivyignore.
//   Reportes en reports/trivy/ (tabla, JSON y JUnit). Desactivable con ENABLE_TRIVY_GATE=false.
//
// US-39 — Despliegue y promoción en Kubernetes: con DEPLOY_PLATFORM=k8s (o CG_DEPLOY_PLATFORM=k8s)
//   las mismas etapas de dev, stage y prod usan deploy/scripts/k8s-deploy.sh (kubectl apply -k con
//   la versión SemVer de US-12 y kubectl rollout status). Si el rollout falla se hace rollback
//   (kubectl rollout undo, US-28) y la etapa falla. Kubeconfig: credencial de archivo 'kubeconfig-<env>'.
//   La notificación de éxito/fallo es la de US-14 (Discord).
//
// US-28 — Rollback en Kubernetes: si el rollout falla, kubectl rollout undo automático. Con los
//   parámetros ROLLBACK_ENV / ROLLBACK_TARGET_VERSION, un build de main solo restaura ese ambiente
//   (prod con aprobación de CG_PROD_APPROVERS). Cada versión verificada queda como estable.
//
// Requisitos del agente: JDK 21, Node.js 20+, librerías de sistema de Chromium (imagen
// infra/bootstrap/jenkins), plugins htmlpublisher y sonar, git, openssh-client y permisos de
// ejecución sobre ./gradlew. Credenciales: 'nexus-credentials', 'circleguard-env-ssh',
// 'sonar-token' (US-10) y 'discord-webhook' (opcional: si falta, la notificación solo deja una
// advertencia).
// =============================================================================
import groovy.json.JsonOutput
import groovy.transform.Field

@Library('circleguard-shared-lib') _

// Contexto, detección y plan se calculan en las primeras etapas y quedan
// disponibles para los bloques `when` y `post` de las etapas posteriores.
@Field def flow = [:]
@Field def detection = [:]
@Field def plan = [:]
// US-10: cobertura de líneas por servicio (JaCoCo XML), usada por la etapa 'Quality Gate'.
@Field def coverageByService = [:]
// US-10: paso sonarQualityGate cargado desde el workspace (como notifyPipeline de US-14): la
// librería global usa la versión de main, así cada rama o PR valida su propia versión del paso.
@Field def sonarQualityGate = null
@Field def versionMap = [:]
// US-13: resultado de cada compuerta de entrega continua (SUCCESS | FAILURE | NOT_RUN).
@Field def deployResults = [deployDev: 'NOT_RUN', verifyDev: 'NOT_RUN', e2eDev: 'NOT_RUN', promoteStage: 'NOT_RUN', verifyStage: 'NOT_RUN']
// US-31: decisión de la compuerta manual a prod (multibranchFlow.prodApprovalDecision) y resultado del release.
@Field def prodApproval = [:]
@Field def prodResults = [deployProd: 'NOT_RUN', verifyProd: 'NOT_RUN']
// US-14: última etapa iniciada; si el build falla, es la etapa que se reporta en Discord.
@Field def pipelineTrack = [stage: '']
// US-22 / US-38 / US-39: paso platformFlow (cargado del workspace) y su plan de etapas.
@Field def platformFlow = null
@Field def platform = [:]
// US-22: resultado del apply de Terraform por ambiente (SUCCESS | FAILURE | SKIPPED | NOT_RUN).
@Field def terraformResults = [dev: 'NOT_RUN', stage: 'NOT_RUN', prod: 'NOT_RUN']
// US-28: rollback manual pedido por parámetro.
@Field def rollbackRequest = [requested: false]

// US-31: distingue timeout de abort en la compuerta manual.
// - TIMEOUT se detecta por el tiempo esperado (no requiere aprobaciones de sandbox).
// - En un ABORTED se intenta leer quién abortó; el sandbox bloquea FlowInterruptedException.getCauses
//   salvo que un administrador apruebe esa firma, y entonces se registra ABORTED sin usuario.
//   Para dejar constancia de quién decide, el formulario ofrece RECHAZAR (registra al usuario siempre).
// Cualquier excepción que no sea una interrupción del input se relanza (un error real no se oculta).
// Se compara por nombre de clase para que el Jenkinsfile siga compilando fuera de Jenkins (caso 11).
Map classifyApprovalInterruption(Throwable interruption, long waitedMs, int timeoutMinutes) {
    if (interruption.getClass().getSimpleName() != 'FlowInterruptedException') {
        throw interruption
    }
    // Margen de 5 s: el paso timeout corta al cumplirse el plazo.
    if (waitedMs >= (timeoutMinutes * 60000L) - 5000L) {
        return [outcome: 'TIMEOUT', abortedBy: '']
    }
    String abortedBy = ''
    try {
        for (def cause in interruption.causes) {
            if (cause.getClass().getSimpleName() == 'Rejection' && cause.getUser() != null) {
                abortedBy = cause.getUser().getId()
            }
        }
    } catch (Throwable ignored) {
        echo '[US-31] El sandbox no permite leer quién abortó (FlowInterruptedException.getCauses); se registra ABORTED sin usuario.'
    }
    return [outcome: 'ABORTED', abortedBy: abortedBy]
}

// La versión desplegada es SIEMPRE la calculada por US-12 y publicada en Nexus; nunca un valor por defecto.
String requireReleaseVersion(Map versionMap) {
    String version = versionMap?.APP_VERSION ?: ''
    if (!version) {
        error('No hay versión SemVer calculada (APP_VERSION); no se despliega una versión no identificada.')
    }
    return version
}

// Credenciales SSH de los nodos (US-05) y del registro Nexus (US-11) para deploy/scripts/*.
void withEnvironmentCredentials(Closure body) {
    withCredentials([
        sshUserPrivateKey(credentialsId: env.ENV_SSH_CREDENTIALS_ID, keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER'),
        usernamePassword(credentialsId: env.NEXUS_CREDENTIALS_ID, usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')
    ]) {
        withEnv(["REGISTRY_URL=${env.DEPLOY_REGISTRY_URL}"]) {
            body()
        }
    }
}

// US-22: credencial AWS de Terraform. Nunca se imprime; tf-pipeline.sh usa la cadena estándar de AWS.
void withTerraformCredentials(Closure body) {
    withCredentials([usernamePassword(credentialsId: env.AWS_TERRAFORM_CREDENTIALS_ID,
                                      usernameVariable: 'AWS_ACCESS_KEY_ID', passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
        withEnv(["AWS_DEFAULT_REGION=${env.TF_STATE_REGION}", "TF_STATE_REGION=${env.TF_STATE_REGION}",
                 "TF_STATE_BUCKET=${env.TF_STATE_BUCKET}"]) {
            body()
        }
    }
}

// US-22: la credencial de Terraform es opcional mientras el equipo no la cree. Sin ella las
// etapas de Terraform se omiten con una advertencia, igual que discord-webhook en US-14.
boolean terraformCredentialsPresent() {
    try {
        withCredentials([usernamePassword(credentialsId: env.AWS_TERRAFORM_CREDENTIALS_ID,
                                          usernameVariable: 'CG_TF_PROBE_ID', passwordVariable: 'CG_TF_PROBE_KEY')]) {
            echo "[US-22] Credencial '${env.AWS_TERRAFORM_CREDENTIALS_ID}' disponible."
        }
        return true
    } catch (Exception missing) {
        echo "[US-22] Advertencia: no existe la credencial '${env.AWS_TERRAFORM_CREDENTIALS_ID}'; se omiten Terraform Plan y Apply (${missing.message})."
        return false
    }
}

// US-39: kubeconfig del clúster k3s de cada ambiente (credencial de archivo 'kubeconfig-<env>').
void withKubeconfig(String envName, Closure body) {
    withCredentials([file(credentialsId: "kubeconfig-${envName}", variable: 'KUBECONFIG')]) {
        withEnv(["REGISTRY_URL=${env.DEPLOY_REGISTRY_URL}"]) {
            body()
        }
    }
}

// US-39 CA2 + US-28: verifica el rollout; si falla, vuelve a la revisión anterior y falla la etapa.
void verifyK8sOrRollback(String envName, String version, String report) {
    withKubeconfig(envName) {
        int rc = sh(returnStatus: true, script: "./deploy/scripts/k8s-deploy.sh verify --env '${envName}' --version '${version}' --report '${report}'")
        if (rc != 0) {
            echo "[US-39] El rollout de ${version} en ${envName} falló; rollback automático (kubectl rollout undo, US-28)."
            sh "./infra/scripts/rollback.sh rollback '${envName}' --platform k8s || true"
            error("Rollout de ${version} en ${envName} incompleto: se restauró la revisión anterior.")
        }
    }
}

// US-14 / SCRUM-70: notifica el resultado en Discord sin alterar nunca el resultado del build.
// El paso se carga desde el workspace (y no como paso global de la Shared Library) porque la
// librería global usa la versión de main: así cada rama/PR valida su propia versión del paso.
void notifyPipelineSafely(Map config) {
    try {
        if (!fileExists('jenkins/vars/notifyPipeline.groovy')) {
            echo '[US-14] No hay workspace con jenkins/vars/notifyPipeline.groovy (¿falló el checkout?); se omite la notificación.'
            return
        }
        def notifier = load 'jenkins/vars/notifyPipeline.groovy'
        notifier.call(config)
    } catch (Throwable err) {
        // Throwable y no solo Exception: un error del intérprete (p. ej. NoSuchMethodError)
        // tampoco debe cambiar el resultado del build.
        echo "[US-14] Advertencia: no se pudo enviar la notificación del pipeline: ${err}"
    }
}

// US-31 / US-32: servicios con umbral mínimo de 60% de cobertura de líneas.
// notification, file y dashboard publican pruebas y cobertura (US-32 / CA3) sin umbral obligatorio.
List<String> CORE_COVERAGE_SERVICES = [
    'circleguard-auth-service',
    'circleguard-identity-service',
    'circleguard-promotion-service',
    'circleguard-form-service',
    'circleguard-gateway-service'
]

pipeline {
    agent any

    options {
        timestamps()
        ansiColor('xterm')
        // US-13: build + publicación de 9 imágenes + despliegue dev + E2E + promoción a stage.
        timeout(time: 90, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        disableConcurrentBuilds(abortPrevious: true)
        skipDefaultCheckout(true)
    }

    parameters {
        booleanParam(
            name: 'FORCE_FULL_BUILD',
            defaultValue: false,
            description: 'Fuerza la compilación de los 8 microservicios y del cliente web (releases o ejecuciones manuales completas).'
        )
        choice(
            name: 'TARGET_ENV',
            choices: ['none', 'dev', 'stage', 'prod'],
            description: 'Ambiente de despliegue solicitado. Solo la rama main puede desplegar; los Pull Requests siempre quedan bloqueados.'
        )
        string(
            name: 'E2E_BASE_URL',
            defaultValue: '',
            trim: true,
            description: 'US-34: URL del cliente web contra la que corre Playwright (p. ej. el ambiente stage). Vacío = exporta mobile/ y lo sirve localmente en el agente.'
        )
        booleanParam(
            name: 'NOTIFY_DISCORD',
            defaultValue: true,
            description: 'US-14: publica el resultado del build en el canal #pipeline de Discord (credencial discord-webhook).'
        )
        booleanParam(
            name: 'ENABLE_SONARQUBE_GATE',
            defaultValue: true,
            description: 'US-10: ejecuta el análisis estático con SonarQube y el bloqueo waitForQualityGate(abortPipeline: true).'
        )
        choice(
            name: 'DEPLOY_PLATFORM',
            choices: ['default', 'compose', 'k8s'],
            description: 'US-39: plataforma de despliegue. default = variable global CG_DEPLOY_PLATFORM (o compose si no existe); k8s = kubectl apply -k por overlay.'
        )
        booleanParam(
            name: 'FORCE_TERRAFORM',
            defaultValue: false,
            description: 'US-22: corre terraform plan (y apply en main) aunque el commit no toque infra/terraform.'
        )
        booleanParam(
            name: 'ENABLE_TRIVY_GATE',
            defaultValue: true,
            description: 'US-38: escaneo bloqueante con Trivy (IaC y las 9 imágenes) con severidad HIGH,CRITICAL.'
        )
        choice(
            name: 'ROLLBACK_ENV',
            choices: ['none', 'dev', 'stage', 'prod'],
            description: 'US-28: restaura este ambiente y no construye ni despliega nada más. Solo main; prod exige aprobación de CG_PROD_APPROVERS.'
        )
        string(
            name: 'ROLLBACK_TARGET_VERSION',
            defaultValue: '',
            trim: true,
            description: 'US-28: versión SemVer a restaurar. Vacío = revisión anterior (k8s) o última versión estable registrada (compose).'
        )
        booleanParam(
            name: 'PUBLISH_GITHUB_STATUS',
            defaultValue: true,
            description: 'Publica los estados PENDING/SUCCESS/FAILURE como Commit Status en GitHub.'
        )
    }

    environment {
        GRADLE_OPTS = '-Dorg.gradle.daemon=false'
        CI = 'true'
        SONAR_PROJECT_KEY = 'circleguard-monorepo'   // US-10
        // US-13: nodos de ambiente (US-05) y registro (US-11). Sobrescribibles con variables
        // globales de Jenkins (CG_DEV_HOST, CG_STAGE_HOST, CG_REGISTRY_URL) sin tocar el repo.
        DEV_HOST = "${env.CG_DEV_HOST ?: '52.15.165.116'}"
        STAGE_HOST = "${env.CG_STAGE_HOST ?: '52.14.89.125'}"
        DEPLOY_REGISTRY_URL = "${env.CG_REGISTRY_URL ?: '18.117.90.15:5000'}"
        ENV_SSH_CREDENTIALS_ID = 'circleguard-env-ssh'
        NEXUS_CREDENTIALS_ID = 'nexus-credentials'
        // US-31: nodo de prod (US-05) y compuerta manual. CG_PROD_APPROVERS = IDs de usuario o
        // grupos de Jenkins separados por comas; vacío => el release a prod se omite (no aprueba cualquiera).
        PROD_HOST = "${env.CG_PROD_HOST ?: '77.113.211.62'}"
        PROD_APPROVERS = "${env.CG_PROD_APPROVERS ?: ''}"
        PROD_APPROVAL_TIMEOUT_MIN = "${env.CG_PROD_APPROVAL_TIMEOUT_MIN ?: '60'}"
        // US-22: backend remoto de US-36 con bloqueo nativo de S3. Si CG_TF_STATE_BUCKET está
        // vacío, tf-pipeline.sh usa circleguard-terraform-state-<ID_CUENTA>. La Región es la del proyecto AWS.
        AWS_TERRAFORM_CREDENTIALS_ID = 'aws-terraform'
        TF_STATE_BUCKET = "${env.CG_TF_STATE_BUCKET ?: ''}"
        TF_STATE_REGION = "${env.CG_AWS_REGION ?: 'us-east-2'}"
        // US-22: el apply crea infraestructura real con costo; se activa a propósito.
        TERRAFORM_APPLY_ENABLED = "${env.CG_TERRAFORM_APPLY ?: 'false'}"
        // US-39: plataforma por defecto cuando DEPLOY_PLATFORM=default.
        DEPLOY_PLATFORM_DEFAULT = "${env.CG_DEPLOY_PLATFORM ?: ''}"
    }

    stages {
        stage('Checkout & Context') {
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    checkout scm
                    flow = multibranchFlow.collectContext()
                    echo "Rama='${flow.branchName}' | PullRequest=${flow.isPullRequest} | main=${flow.isMainBranch} | ContextoGitHub='${flow.statusContext}'"
                    if (params.PUBLISH_GITHUB_STATUS) {
                        publishBuildStatus(state: 'PENDING', flow: flow, description: 'CircleGuard CI en ejecución')
                    }
                }
            }
        }

        stage('Detect Changed Components') {
            steps {
                script {
                    runDetectChangedComponentsStage()
                }
            }
        }

        stage('Calculate SemVer') {
            when {
                expression { plan?.runHeavyBuild == true }
            }
            steps {
                script {
                    runCalculateSemVerStage()
                }
            }
        }

        stage('Compile & Test Backend') {
            when {
                expression { plan?.runBackendBuild == true }
            }
            steps {
                script {
                    runCompileTestBackendStage()
                }
            }
        }

        stage('Coverage Gate (núcleo + gateway)') {
            when {
                expression { plan?.runBackendBuild == true && plan.backendServices.any { it in CORE_COVERAGE_SERVICES } }
            }
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    // US-31 / US-32 CA1: falla el build si auth, identity, promotion, form o gateway bajan del 60% de líneas.
                    List<String> coreServices = plan.backendServices.findAll { it in CORE_COVERAGE_SERVICES }
                    String tasks = coreServices.collect { ":services:${it}:jacocoTestCoverageVerification" }.join(' ')
                    echo "Verificando cobertura de líneas >= 60% en: ${coreServices.join(', ')}"
                    sh "./gradlew ${tasks} --no-daemon --stacktrace"
                }
            }
        }

        // US-10 CA2: análisis estático en SonarQube (servidor 'SonarQube' de jenkins/ci/jenkins.yaml).
        stage('SonarQube Analysis') {
            when {
                expression { plan?.runSonarAnalysis == true }
            }
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    String sonarCommand = sonarQualityGate.buildSonarGradleCommand(
                        plan.backendServices,
                        [projectKey: env.SONAR_PROJECT_KEY, skipTests: true, daemon: false]
                    )
                    withSonarQubeEnv('SonarQube') {
                        sh "${sonarCommand}"
                    }
                    writeFile(
                        file: 'reports/ci/sonarqube-analysis.json',
                        text: JsonOutput.prettyPrint(JsonOutput.toJson([
                            projectKey     : env.SONAR_PROJECT_KEY,
                            sonarServerName: 'SonarQube',
                            backendServices: plan.backendServices,
                            xmlReportPaths : sonarQualityGate.resolveJacocoXmlReportPaths(plan.backendServices),
                            command        : sonarCommand
                        ]))
                    )
                }
            }
        }

        // US-10 CA3: bloquea el pipeline (antes de publicar y desplegar) si falla el Quality Gate.
        stage('Quality Gate') {
            when {
                expression { plan?.runQualityGate == true }
            }
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    timeout(time: 10, unit: 'MINUTES') {
                        Map gateResult = sonarQualityGate.enforceQualityGate([
                            minCoreCoverage  : 60.0d,
                            coverageByService: coverageByService
                        ])
                        writeFile(
                            file: 'reports/ci/quality-gate.json',
                            text: JsonOutput.prettyPrint(JsonOutput.toJson(gateResult))
                        )
                    }
                }
            }
        }

        stage('Compile & Test Web') {
            when {
                expression { plan?.runMobileBuild == true }
            }
            steps {
                script { pipelineTrack.stage = env.STAGE_NAME }   // US-14
                dir('mobile') {
                    sh 'npm ci --no-audit --no-fund'
                    sh 'npm run test -- --ci --watchAll=false'
                }
            }
        }

        stage('E2E Playwright') {
            when {
                expression { plan?.runMobileBuild == true || (params.E2E_BASE_URL?.trim() ? true : false) }
            }
            environment {
                EXPO_NO_TELEMETRY = '1'
            }
            steps {
                script {
                    runE2EPlaywrightStage()
                }
            }
            post {
                always {
                    // CA2: publica JUnit (tendencia de pruebas) y el reporte HTML navegable de Playwright.
                    junit allowEmptyResults: true, testResults: 'e2e/reports/junit/*.xml'
                    publishHTML(target: [
                        reportName           : 'Playwright E2E',
                        reportDir            : 'e2e/reports/html',
                        reportFiles          : 'index.html',
                        keepAll              : true,
                        alwaysLinkToLastBuild: true,
                        allowMissing         : true
                    ])
                    archiveArtifacts artifacts: 'e2e/reports/**,e2e/test-results/**', allowEmptyArchive: true
                }
            }
        }

        stage('Validate Compose Environments') {
            when {
                expression { plan?.runHeavyBuild == true }
            }
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    echo 'Validando archivos docker-compose para dev, stage y prod (US-08)...'
                    sh 'chmod +x deploy/compose/validate-compose.sh'
                    sh 'IMAGE_TAG="' + (versionMap.APP_VERSION ?: '0.1.0') + '" ./deploy/compose/validate-compose.sh'
                    // US-13: los scripts de despliegue/promoción se prueban también en los PR (sin Docker ni credenciales).
                    sh 'chmod +x deploy/scripts/*.sh && ./deploy/scripts/test-deploy-scripts.sh'
                    // US-22 / US-38 / US-39 / US-28: scripts de plataforma con binarios simulados.
                    sh 'chmod +x infra/scripts/*.sh infra/terraform/scripts/*.sh && ./infra/scripts/test-platform-scripts.sh && ./infra/scripts/test-rollback.sh'
                }
            }
        }

        // US-22 CA1: plan de los tres ambientes, archivado como artefacto (también en los PR).
        stage('Terraform Plan') {
            when {
                expression { platform?.runTerraformPlan == true }
            }
            steps {
                script {
                    runTerraformPlanStage()
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/terraform/*-plan.txt,reports/terraform/*-summary.json,reports/terraform/*-plan.json', allowEmptyArchive: true
                }
            }
        }

        // US-21: namespaces y middleware de Kubernetes (Kustomize). Corre en todo build,
        // también en los PR: no necesita clúster ni credenciales y tarda menos de un minuto.
        stage('Validate Kubernetes Manifests') {
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    echo 'Validando namespaces y middleware de Kubernetes para dev, stage y prod (US-21)...'
                    sh 'bash deploy/k8s/scripts/validate.sh'
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/k8s/**', allowEmptyArchive: true
                }
            }
        }

        // US-38 CA1: misconfiguraciones HIGH/CRITICAL en el IaC rompen el build.
        stage('Trivy IaC Scan') {
            when {
                expression { platform?.runTrivyConfig == true }
            }
            steps {
                script {
                    runTrivyIaCScanStage()
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/trivy/junit/config-*.xml'
                    archiveArtifacts artifacts: 'reports/trivy/config-*,reports/trivy/summary-config.json', allowEmptyArchive: true
                }
            }
        }

        // US-38: las imágenes se construyen, se escanean y solo entonces se publican.
        stage('Build Images') {
            when {
                expression { flow?.isMainBranch == true && plan?.runHeavyBuild == true }
            }
            steps {
                script {
                    runBuildImagesStage()
                }
            }
        }

        stage('Trivy Image Scan') {
            when {
                expression { flow?.isMainBranch == true && plan?.runHeavyBuild == true && platform?.runTrivyImages == true }
            }
            steps {
                script {
                    runTrivyImageScanStage()
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/trivy/junit/image-*.xml'
                    archiveArtifacts artifacts: 'reports/trivy/image-*,reports/trivy/summary-image.json', allowEmptyArchive: true
                }
            }
        }

        stage('Publish Images to Nexus') {
            when {
                expression { flow?.isMainBranch == true && plan?.runHeavyBuild == true }
            }
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    String semver = versionMap.APP_VERSION ?: '0.1.0'
                    echo "Publicando en Nexus las imágenes ya escaneadas con versión semántica: ${semver} (US-11 / US-38)..."
                    withCredentials([usernamePassword(
                        credentialsId: 'nexus-credentials',
                        usernameVariable: 'NEXUS_USER',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )]) {
                        sh """
                            REGISTRY_URL="18.117.90.15:5000" \
                            REGISTRY_USER="\${NEXUS_USER}" \
                            REGISTRY_PASSWORD="\${NEXUS_PASSWORD}" \
                            VERSION="${semver}" \
                            PUSH_ONLY=true \
                            ./infra/scripts/publish-docker-images.sh
                        """
                    }
                }
            }
        }

        stage('Generate Release Notes & Tag') {
            when {
                expression { flow?.isMainBranch == true && plan?.rollbackOnly != true }
            }
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    String semver = versionMap.APP_VERSION ?: '0.1.0'
                    echo "Generando Release Notes automaticas y tag Git para ${semver} (US-18 y US-12)..."
                    sh 'chmod +x infra/scripts/generate-release-notes.sh infra/scripts/git-tag-release.sh'
                    sh "./infra/scripts/generate-release-notes.sh --version '${semver}'"
                    sh "./infra/scripts/git-tag-release.sh --version '${semver}'"
                }
            }
        }

        // ---------------------------------------------------------------------
        // US-13: entrega continua dev -> stage. Cada etapa marca su compuerta en
        // FAILURE antes de empezar y en SUCCESS solo al terminar bien; si una falla,
        // las siguientes se omiten y stage nunca recibe la versión.
        // ---------------------------------------------------------------------
        // US-22 CA2: la infraestructura de dev se aplica antes de desplegar la aplicación en dev.
        stage('Terraform Apply dev') {
            when {
                expression { plan?.autoDeployDev == true && platform?.terraformApply == true }
            }
            steps {
                script {
                    runTerraformApplyDevStage()
                }
            }
        }

        stage('Deploy to dev') {
            when {
                expression { plan?.autoDeployDev == true }
            }
            steps {
                script {
                    runDeployToDevStage()
                }
            }
        }

        stage('Verify dev health') {
            when {
                expression { plan?.autoDeployDev == true }
            }
            steps {
                script {
                    runVerifyDevHealthStage()
                }
            }
        }

        stage('E2E against dev') {
            when {
                expression { plan?.autoDeployDev == true }
            }
            steps {
                script {
                    runE2EAgainstDevStage()
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'e2e/reports/dev/junit/*.xml'
                    publishHTML(target: [
                        reportName           : 'Playwright E2E (dev)',
                        reportDir            : 'e2e/reports/dev/html',
                        reportFiles          : 'index.html',
                        keepAll              : true,
                        alwaysLinkToLastBuild: true,
                        allowMissing         : true
                    ])
                    archiveArtifacts artifacts: 'e2e/reports/dev/**,e2e/test-results/dev/**', allowEmptyArchive: true
                }
            }
        }

        // US-22 CA2: apply automático en stage, con la misma compuerta que la aplicación (dev + E2E).
        stage('Terraform Apply stage') {
            when {
                expression { plan?.promoteToStage == true && platform?.terraformApply == true }
            }
            steps {
                script {
                    runTerraformApplyStageStage()
                }
            }
        }

        stage('Promote to stage') {
            when {
                expression { plan?.promoteToStage == true }
            }
            steps {
                script {
                    runPromoteToStageStage()
                }
            }
        }

        stage('Verify stage health') {
            when {
                expression { plan?.promoteToStage == true }
            }
            steps {
                script {
                    runVerifyStageHealthStage()
                }
            }
        }

        // ---------------------------------------------------------------------
        // US-31: aprobación manual y despliegue verificado a prod. Solo se ofrece la
        // versión que esta misma ejecución validó en dev (E2E) y stage.
        // ---------------------------------------------------------------------
        stage('Approve prod release') {
            when {
                expression { plan?.prodRelease == true && deployResults.verifyStage == 'SUCCESS' }
            }
            steps {
                script {
                    runApproveProdReleaseStage()
                }
            }
        }

        // US-22 CA2: en prod, Terraform solo se aplica con la aprobación manual de US-31.
        stage('Terraform Apply prod') {
            when {
                expression { plan?.prodRelease == true && platform?.terraformApply == true && prodApproval?.deploy == true }
            }
            steps {
                script {
                    runTerraformApplyProdStage()
                }
            }
        }

        stage('Deploy to prod') {
            when {
                expression { plan?.prodRelease == true && prodApproval?.deploy == true }
            }
            steps {
                script {
                    runDeployToProdStage()
                }
            }
        }

        stage('Verify prod health') {
            when {
                expression { plan?.prodRelease == true && prodApproval?.deploy == true && prodResults.deployProd == 'SUCCESS' }
            }
            steps {
                script {
                    runVerifyProdHealthStage()
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/ci/junit/health-prod.xml'
                }
            }
        }

        // US-28 CA1/CA2: rollback manual. Restaura con la plataforma activa y, en prod, solo con aprobación.
        stage('Manual Rollback') {
            when {
                expression { rollbackRequest?.allowed == true }
            }
            steps {
                script {
                    runManualRollbackStage()
                }
            }
        }

        stage('Release Gate') {
            when {
                expression { plan?.deploymentAllowed == true }
            }
            steps {
                script {
                    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
                    Map decision = multibranchFlow.requireDeploymentAllowed(flow, plan.targetEnv)
                    echo "Despliegue autorizado a '${decision.targetEnv}' (aprobación manual requerida: ${decision.requiresApproval})."
                    echo 'dev y stage se despliegan automáticamente en main (US-13); prod se libera con la etapa "Approve prod release" de cada build de main (US-31).'
                    echo 'Esta compuerta garantiza que ningún Pull Request ni rama distinta de main alcance un ambiente.'
                    writeFile(
                        file: "reports/ci/release-gate-${decision.targetEnv}.json",
                        text: JsonOutput.prettyPrint(JsonOutput.toJson(decision + [flow: flow]))
                    )
                }
            }
        }
    }

    post {
        success {
            script {
                if (params.PUBLISH_GITHUB_STATUS) {
                    publishBuildStatus(state: 'SUCCESS', flow: flow, description: 'CircleGuard CI finalizó correctamente')
                }
            }
        }
        failure {
            script {
                if (params.PUBLISH_GITHUB_STATUS) {
                    // Si la entrega continua se detuvo, el estado de GitHub explica qué compuerta lo bloqueó (CA3).
                    String failureDescription = currentBuild.description ?: 'CircleGuard CI falló'
                    publishBuildStatus(state: 'FAILURE', flow: flow, description: failureDescription)
                }
            }
        }
        aborted {
            script {
                if (params.PUBLISH_GITHUB_STATUS) {
                    publishBuildStatus(state: 'ABORTED', flow: flow, description: 'CircleGuard CI fue abortado')
                }
            }
        }
        // Declarative ejecuta `always` antes que success/failure: el registro de la promoción
        // ya existe cuando se publica el estado en GitHub.
        always {
            script {
                if (plan?.autoDeployDev == true) {
                    // US-13 / CA3: la decisión de promoción queda registrada SIEMPRE, también si falló.
                    Map promotion = multibranchFlow.promotionDecision(deployResults, [version: versionMap?.APP_VERSION ?: ''])
                    Map record = promotion + [
                        gatesDetail    : deployResults,
                        stageDeployed  : deployResults.promoteStage == 'SUCCESS',
                        stageHealthy   : deployResults.verifyStage == 'SUCCESS',
                        devHost        : env.DEV_HOST,
                        stageHost      : env.STAGE_HOST,
                        registry       : env.DEPLOY_REGISTRY_URL,
                        commit         : env.GIT_COMMIT ?: '',
                        buildUrl       : env.BUILD_URL ?: '',
                        buildNumber    : env.BUILD_NUMBER ?: '',
                        buildStartedMs : currentBuild.startTimeInMillis
                    ]
                    sh 'mkdir -p reports/ci'
                    writeFile file: 'reports/ci/promotion-stage.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(record))
                    String stageNote = promotion.promote && deployResults.verifyStage != 'SUCCESS'
                        ? " | stage: despliegue=${deployResults.promoteStage}, health=${deployResults.verifyStage}"
                        : ''
                    currentBuild.description = "${promotion.status}: ${promotion.reason}${stageNote}"
                    echo "[US-13] ${currentBuild.description}"
                }
                if (plan?.prodRelease == true) {
                    // US-31 / CA2: quién aprobó o rechazó, qué versión y con qué resultado; siempre, también si no se llegó a la compuerta.
                    Map approval = prodApproval ?: [
                        targetEnv: 'prod', status: 'NOT_RUN', deploy: false,
                        version  : versionMap?.APP_VERSION ?: '',
                        reason   : 'La compuerta de prod no se ejecutó: la versión no quedó verificada en stage.'
                    ]
                    Map prodRecord = approval + [
                        deployProd     : prodResults.deployProd,
                        verifyProd     : prodResults.verifyProd,
                        prodHost       : env.PROD_HOST,
                        commit         : env.GIT_COMMIT ?: '',
                        buildUrl       : env.BUILD_URL ?: '',
                        buildNumber    : env.BUILD_NUMBER ?: '',
                        buildStartedMs : currentBuild.startTimeInMillis
                    ]
                    sh 'mkdir -p reports/ci'
                    writeFile file: 'reports/ci/prod-approval.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(prodRecord))
                    String prodNote = "PROD ${approval.status}" +
                        (approval.approver ? " por ${approval.approver}" : '') +
                        (approval.version ? " (v${approval.version})" : '') +
                        (approval.deploy ? " | despliegue=${prodResults.deployProd}, health=${prodResults.verifyProd}" : '')
                    currentBuild.description = currentBuild.description ? "${currentBuild.description} | ${prodNote}" : prodNote
                    echo "[US-31] ${prodNote} — ${approval.reason}"
                }
            }
            junit allowEmptyResults: true, testResults: '**/build/test-results/test/*.xml'
            script {
                // US-31 / US-32 CA3: publica la cobertura JaCoCo de los ocho servicios (tendencia + detalle por clase) y archiva los reportes HTML/XML.
                if (sh(returnStatus: true, script: 'ls services/*/build/jacoco/test.exec >/dev/null 2>&1') == 0) {
                    jacoco(
                        execPattern: 'services/*/build/jacoco/test.exec',
                        classPattern: 'services/*/build/classes/java/main',
                        sourcePattern: 'services/*/src/main/java',
                        exclusionPattern: '**/*Application.class'
                    )
                }
            }
            script {
                if (platform?.terraformApply == true) {
                    // US-22: qué ambientes recibieron el apply de Terraform en este build.
                    sh 'mkdir -p reports/ci'
                    writeFile file: 'reports/ci/terraform-apply.json',
                              text: JsonOutput.prettyPrint(JsonOutput.toJson(terraformResults + [files: platform.terraformFiles]))
                }
            }
            // reports/ci/** incluye promotion-stage.json y health-<env>.json (US-13).
            // reports/terraform y reports/trivy: planes de US-22 y escaneos de US-38 (sin los .tfplan binarios).
            archiveArtifacts artifacts: 'reports/ci/**,reports/trivy/**,reports/terraform/*.txt,reports/terraform/*.json,docs/release-notes/**,services/*/build/reports/jacoco/test/**', allowEmptyArchive: true
        }
        // US-14 / SCRUM-70 (CA1): `cleanup` corre al final, con el resultado definitivo del build
        // (incluida la descripción de US-13 / US-31), y nunca cambia ese resultado.
        cleanup {
            script {
                if (params.NOTIFY_DISCORD != false) {
                    notifyPipelineSafely(
                        status     : currentBuild.currentResult,
                        flow       : flow,
                        version    : versionMap?.APP_VERSION ?: '',
                        failedStage: pipelineTrack.stage,
                        details    : currentBuild.description ?: ''
                    )
                }
            }
        }
    }
}

// =============================================================================
// Cuerpos de las etapas. Viven fuera del bloque pipeline porque Groovy CPS compila todo ese
// bloque en un solo método de la JVM, que no puede pasar de 64 KB. Cada método de aquí se
// compila aparte. Usan las variables @Field de arriba; nada más cambia respecto a tenerlos inline.
// =============================================================================

void runDetectChangedComponentsStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    detection = detectChangedServices(forceAll: params.FORCE_FULL_BUILD as boolean)
    plan = multibranchFlow.planPipeline(flow, detection, [
        targetEnv: params.TARGET_ENV,
        forceFullBuild: params.FORCE_FULL_BUILD as boolean,
        enableSonar: params.ENABLE_SONARQUBE_GATE as boolean   // US-10
    ])

    echo pipelineUtils.formatDetectionSummary(detection)
    echo multibranchFlow.formatPlanSummary(plan)

    // Guarda dura CA2: si alguien solicita un despliegue no permitido
    // (por ejemplo TARGET_ENV=prod en un PR), el build falla de inmediato.
    if (plan.deploymentRequested && !plan.deploymentAllowed) {
        multibranchFlow.requireDeploymentAllowed(flow, params.TARGET_ENV)
    }

    // US-22 / US-38 / US-39: etapas de plataforma (Terraform, Trivy y plataforma de despliegue).
    platformFlow = load 'jenkins/vars/platformFlow.groovy'
    boolean k8sOverlaysPresent = ['dev', 'stage', 'prod'].every { fileExists("deploy/k8s/overlays/${it}/kustomization.yaml") }
    platform = platformFlow.planPlatform(plan, detection, [
        forceTerraform    : params.FORCE_TERRAFORM as boolean,
        deployPlatform    : params.DEPLOY_PLATFORM,
        configuredPlatform: env.DEPLOY_PLATFORM_DEFAULT,
        k8sOverlaysPresent: k8sOverlaysPresent,
        enableTrivy       : params.ENABLE_TRIVY_GATE as boolean,
        terraformCredentials : terraformCredentialsPresent(),
        terraformApplyEnabled: env.TERRAFORM_APPLY_ENABLED == 'true'
    ])
    echo platformFlow.formatPlatformSummary(platform)

    // US-28: un rollback manual reemplaza el resto del flujo (no hay build ni despliegue nuevo).
    rollbackRequest = platformFlow.rollbackRequest(flow, params.ROLLBACK_ENV, params.ROLLBACK_TARGET_VERSION)
    if (rollbackRequest.requested) {
        if (!rollbackRequest.allowed) {
            error(rollbackRequest.reason)
        }
        Map rollbackPlans = platformFlow.rollbackOnlyPlans(plan, platform)
        plan = rollbackPlans.plan
        platform = rollbackPlans.platform
        echo "[US-28] ${rollbackRequest.reason}"
    }

    sh 'mkdir -p reports/ci'
    writeFile file: 'reports/ci/change-detection.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(detection))
    writeFile file: 'reports/ci/pipeline-plan.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(plan))
    writeFile file: 'reports/ci/platform-plan.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(platform))
}

void runCalculateSemVerStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    echo 'Calculando version semantica dinamica a partir de commits (US-12)...'
    sh 'chmod +x infra/scripts/calculate-semver.sh'
    sh './infra/scripts/calculate-semver.sh --export reports/ci/version.env --format env'

    def lines = readFile('reports/ci/version.env').split('\n')
    for (int i = 0; i < lines.length; i++) {
        def entry = lines[i].trim()
        if (entry && entry.contains('=')) {
            def parts = entry.split('=', 2)
            versionMap[parts[0].trim()] = parts[1].trim()
        }
    }
    echo "Version SemVer resultante: ${versionMap.APP_VERSION} (Tag: ${versionMap.GIT_TAG}, Incremento: ${versionMap.SEMVER_BUMP})"
}

void runCompileTestBackendStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    // US-31: JaCoCo aplicado en build.gradle.kts; cada servicio genera su reporte XML/HTML.
    String gradleCommand = pipelineUtils.buildGradleCommandForServices(
        plan.backendServices,
        [includeTests: true, includeJacoco: true, daemon: false]
    )
    echo "Servicios backend afectados (${plan.backendServices.size()}): ${plan.backendServices.join(', ')}"
    sh "${gradleCommand}"

    // US-10 CA1: cobertura de líneas por servicio para el Quality Gate. La publicación
    // del reporte JaCoCo en Jenkins la hace post { always } (US-31 / US-32).
    sonarQualityGate = load 'jenkins/vars/sonarQualityGate.groovy'
    coverageByService = sonarQualityGate.collectServiceCoverage(plan.backendServices, '.')
    writeFile(
        file: 'reports/ci/jacoco-coverage.json',
        text: JsonOutput.prettyPrint(JsonOutput.toJson([
            xmlReportPaths   : sonarQualityGate.resolveJacocoXmlReportPaths(plan.backendServices),
            coverageByService: coverageByService
        ]))
    )
}

void runE2EPlaywrightStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    // CA1: BASE_URL parametrizable; vacío => playwright.config.ts sirve mobile/dist en el agente.
    String e2eBaseUrl = (params.E2E_BASE_URL ?: '').trim()
    if (e2eBaseUrl) {
        echo "Ejecutando E2E contra BASE_URL=${e2eBaseUrl} (APIs reales, E2E_MOCK_API=false)."
    } else {
        echo 'E2E_BASE_URL vacío: exportando el cliente web de Expo para servirlo en el agente (APIs simuladas).'
        dir('mobile') {
            sh 'test -d node_modules || npm ci --no-audit --no-fund'
            sh 'npx expo export --platform web'
        }
    }
    withEnv([
        "BASE_URL=${e2eBaseUrl}",
        "E2E_MOCK_API=${e2eBaseUrl ? 'false' : 'true'}"
    ]) {
        dir('e2e') {
            sh 'npm ci --no-audit --no-fund'
            // Las librerías de sistema ya vienen en la imagen de Jenkins; solo se descarga Chromium.
            sh 'npx playwright install chromium'
            // CA2 + CA3: headless (CI=true) y sin '|| true': cualquier spec fallido rompe la etapa y el build.
            sh 'npx playwright test'
        }
    }
}

void runTerraformPlanStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    sh 'chmod +x infra/terraform/scripts/*.sh'
    withTerraformCredentials {
        for (String tfEnv in platform.terraformEnvs) {
            sh "./infra/terraform/scripts/tf-pipeline.sh plan --env '${tfEnv}'"
        }
    }
}

void runTrivyIaCScanStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    sh 'chmod +x infra/scripts/trivy-scan.sh && ./infra/scripts/trivy-scan.sh config --target infra/terraform --target deploy/k8s'
}

void runBuildImagesStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    String semver = versionMap.APP_VERSION ?: '0.1.0'
    echo "Construyendo las 9 imágenes con versión semántica ${semver} (US-11), sin publicar todavía (US-38)..."
    sh 'chmod +x infra/scripts/publish-docker-images.sh'
    sh """
        REGISTRY_URL="${env.DEPLOY_REGISTRY_URL}" \
        VERSION="${semver}" \
        DO_PUSH=false SKIP_LOGIN=true \
        ./infra/scripts/publish-docker-images.sh
    """
}

void runTrivyImageScanStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    String semver = versionMap.APP_VERSION ?: '0.1.0'
    sh "./infra/scripts/trivy-scan.sh image --version '${semver}' --registry '${env.DEPLOY_REGISTRY_URL}'"
}

void runTerraformApplyDevStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    Map tfDecision = platformFlow.terraformApplyDecision(platform, 'dev')
    echo "[US-22] ${tfDecision.reason}"
    terraformResults.dev = 'FAILURE'
    withTerraformCredentials {
        sh "./infra/terraform/scripts/tf-pipeline.sh apply --env 'dev'"
    }
    terraformResults.dev = 'SUCCESS'
}

void runDeployToDevStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    deployResults.deployDev = 'FAILURE'
    String version = requireReleaseVersion(versionMap)
    if (platform?.deployPlatform == 'k8s') {
        // US-39 CA1: kubectl apply -k del overlay dev con la etiqueta SemVer de US-12.
        echo "Desplegando automáticamente ${version} en el namespace circleguard-dev (US-39)..."
        withKubeconfig('dev') {
            sh "./deploy/scripts/k8s-deploy.sh deploy --env dev --version '${version}'"
        }
    } else {
        echo "Desplegando automáticamente ${version} en dev (${env.DEV_HOST}) (US-13 / CA1)..."
        withEnvironmentCredentials {
            sh "./deploy/scripts/environment.sh deploy --env dev --version '${version}' --host '${env.DEV_HOST}'"
        }
    }
    deployResults.deployDev = 'SUCCESS'
}

void runVerifyDevHealthStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    deployResults.verifyDev = 'FAILURE'
    String version = requireReleaseVersion(versionMap)
    if (platform?.deployPlatform == 'k8s') {
        // US-39 CA2: kubectl rollout status; si falla, rollback y la etapa falla.
        verifyK8sOrRollback('dev', version, 'reports/ci/health-dev.json')
    } else {
        echo "Verificando healthchecks de los 12 contenedores de dev para ${version} (US-13 / CA1)..."
        withEnvironmentCredentials {
            sh "./deploy/scripts/environment.sh verify --env dev --version '${version}' --host '${env.DEV_HOST}' --report reports/ci/health-dev.json"
        }
    }
    // US-28: la versión verificada queda como estable; es la que restaura un rollback sin versión.
    sh "./infra/scripts/rollback.sh mark-stable 'dev' '${version}' || true"
    deployResults.verifyDev = 'SUCCESS'
}

void runE2EAgainstDevStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    deployResults.e2eDev = 'FAILURE'
    echo 'Ejecutando contra los servicios REALES de dev los flujos E2E de US-17 (@us17, @smoke) y los contratos @deployed (US-13 / CA2)...'
    if (platform?.deployPlatform == 'k8s') {
        withKubeconfig('dev') {
            sh './deploy/scripts/run-e2e.sh --env dev --k8s'
        }
    } else {
        withEnvironmentCredentials {
            sh "./deploy/scripts/run-e2e.sh --env dev --host '${env.DEV_HOST}'"
        }
    }
    deployResults.e2eDev = 'SUCCESS'
}

void runTerraformApplyStageStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    Map tfDecision = platformFlow.terraformApplyDecision(platform, 'stage', [deployResults: deployResults])
    echo "[US-22] ${tfDecision.reason}"
    if (!tfDecision.apply) {
        terraformResults.stage = 'SKIPPED'
        error(tfDecision.reason)
    }
    terraformResults.stage = 'FAILURE'
    withTerraformCredentials {
        sh "./infra/terraform/scripts/tf-pipeline.sh apply --env 'stage'"
    }
    terraformResults.stage = 'SUCCESS'
}

void runPromoteToStageStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    String version = requireReleaseVersion(versionMap)
    Map promotion = multibranchFlow.promotionDecision(deployResults, [version: version])
    if (!promotion.promote) {
        error(promotion.reason)
    }
    deployResults.promoteStage = 'FAILURE'
    if (platform?.deployPlatform == 'k8s') {
        // US-39 CA3: promoción automática a stage tras E2E, en el namespace circleguard-stage.
        echo "${promotion.reason} Desplegando en el namespace circleguard-stage (US-39)..."
        withKubeconfig('stage') {
            sh "./deploy/scripts/k8s-deploy.sh deploy --env stage --version '${version}'"
        }
    } else {
        echo "${promotion.reason} Desplegando en stage (${env.STAGE_HOST})..."
        withEnvironmentCredentials {
            sh "./deploy/scripts/environment.sh deploy --env stage --version '${version}' --host '${env.STAGE_HOST}'"
        }
    }
    deployResults.promoteStage = 'SUCCESS'
}

void runVerifyStageHealthStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    deployResults.verifyStage = 'FAILURE'
    String version = requireReleaseVersion(versionMap)
    if (platform?.deployPlatform == 'k8s') {
        verifyK8sOrRollback('stage', version, 'reports/ci/health-stage.json')
    } else {
        withEnvironmentCredentials {
            sh "./deploy/scripts/environment.sh verify --env stage --version '${version}' --host '${env.STAGE_HOST}' --report reports/ci/health-stage.json"
        }
    }
    // US-28: la versión verificada queda como estable; es la que restaura un rollback sin versión.
    sh "./infra/scripts/rollback.sh mark-stable 'stage' '${version}' || true"
    deployResults.verifyStage = 'SUCCESS'
}

void runApproveProdReleaseStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    String version = requireReleaseVersion(versionMap)
    List<String> approvers = multibranchFlow.parseProdApprovers(env.PROD_APPROVERS)
    int timeoutMinutes = Integer.parseInt(env.PROD_APPROVAL_TIMEOUT_MIN ?: '60')
    Map approvalConfig = [validatedVersion: version, approvers: approvers]
    int attempts = 0
    if (approvers.isEmpty()) {
        prodApproval = multibranchFlow.prodApprovalDecision([:], approvalConfig + [outcome: 'NOT_CONFIGURED'])
    } else {
        // CA1: el pipeline se detiene hasta que un aprobador autorizado decide (o vence el plazo).
        while (attempts < 3) {
            attempts++
            long waitStartedMs = System.currentTimeMillis()
            try {
                timeout(time: timeoutMinutes, unit: 'MINUTES') {
                    Map response = input(
                        id: 'ProdRelease',
                        message: "¿Aprobar el release ${version} a PRODUCCIÓN? (validado en dev + E2E y stage)",
                        ok: 'Enviar decisión',
                        submitter: approvers.join(','),
                        submitterParameter: 'APPROVER',
                        parameters: [
                            choice(name: 'DECISION', choices: ['RECHAZAR', 'APROBAR'],
                                   description: 'APROBAR despliega en prod; RECHAZAR deja prod intacto. Ambas quedan registradas.'),
                            choice(name: 'VERSION', choices: [version],
                                   description: 'Versión validada en dev (E2E) y stage en esta ejecución.'),
                            string(name: 'COMMENT', defaultValue: '', trim: true,
                                   description: 'Justificación o ID de RFC (obligatorio para aprobar).')
                        ]
                    )
                    prodApproval = multibranchFlow.prodApprovalDecision(response, approvalConfig + [outcome: 'SUBMITTED'])
                }
            } catch (Exception interruption) {
                prodApproval = multibranchFlow.prodApprovalDecision([:], approvalConfig +
                    classifyApprovalInterruption(interruption, System.currentTimeMillis() - waitStartedMs, timeoutMinutes))
            }
            if (prodApproval.status != 'INVALID') {
                break
            }
            echo "[US-31] Respuesta inválida (${attempts}/3): ${prodApproval.reason}"
        }
    }
    prodApproval = prodApproval + [attempts: attempts, timeoutMinutes: timeoutMinutes]
    echo "[US-31] ${prodApproval.status}: ${prodApproval.reason}"
    if (prodApproval.status == 'ABORTED') {
        currentBuild.result = 'ABORTED'
    } else if (prodApproval.status == 'INVALID') {
        error(prodApproval.reason)
    }
}

void runTerraformApplyProdStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    Map tfDecision = platformFlow.terraformApplyDecision(platform, 'prod', [prodApproval: prodApproval])
    echo "[US-22] ${tfDecision.reason}"
    if (!tfDecision.apply) {
        terraformResults.prod = 'SKIPPED'
        error(tfDecision.reason)
    }
    terraformResults.prod = 'FAILURE'
    withTerraformCredentials {
        sh "./infra/terraform/scripts/tf-pipeline.sh apply --env 'prod'"
    }
    terraformResults.prod = 'SUCCESS'
}

void runDeployToProdStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    prodResults.deployProd = 'FAILURE'
    echo "Desplegando ${prodApproval.version} en PRODUCCIÓN (${env.PROD_HOST}), aprobado por ${prodApproval.approver} (US-31)..."
    if (platform?.deployPlatform == 'k8s') {
        withKubeconfig('prod') {
            sh "./deploy/scripts/k8s-deploy.sh deploy --env prod --version '${prodApproval.version}'"
        }
    } else {
        withEnvironmentCredentials {
            sh "./deploy/scripts/environment.sh deploy --env prod --version '${prodApproval.version}' --host '${env.PROD_HOST}'"
        }
    }
    prodResults.deployProd = 'SUCCESS'
}

void runVerifyProdHealthStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    prodResults.verifyProd = 'FAILURE'
    try {
        if (platform?.deployPlatform == 'k8s') {
            verifyK8sOrRollback('prod', prodApproval.version, 'reports/ci/health-prod.json')
        } else {
            withEnvironmentCredentials {
                sh "./deploy/scripts/environment.sh verify --env prod --version '${prodApproval.version}' --host '${env.PROD_HOST}' --report reports/ci/health-prod.json"
            }
        }
    } finally {
        // CA3: el resultado (sano o no) se publica como pruebas JUnit, un caso por contenedor.
        sh 'if [ -s reports/ci/health-prod.json ]; then ./deploy/scripts/health-report-to-junit.sh reports/ci/health-prod.json reports/ci/junit/health-prod.xml; fi'
    }
    // US-28: la versión verificada queda como estable; es la que restaura un rollback sin versión.
    sh "./infra/scripts/rollback.sh mark-stable 'prod' '${prodApproval.version}' || true"
    prodResults.verifyProd = 'SUCCESS'
}

void runManualRollbackStage() {
    pipelineTrack.stage = env.STAGE_NAME   // US-14: etapa en curso para la notificación
    String rbEnv = rollbackRequest.env
    if (rollbackRequest.requiresApproval) {
        List<String> approvers = multibranchFlow.parseProdApprovers(env.PROD_APPROVERS)
        if (approvers.isEmpty()) {
            error('[US-28] Rollback de prod sin CG_PROD_APPROVERS configurado: no se ejecuta.')
        }
        timeout(time: Integer.parseInt(env.PROD_APPROVAL_TIMEOUT_MIN ?: '60'), unit: 'MINUTES') {
            input(id: 'ProdRollback', message: "¿Aprobar el rollback de PRODUCCIÓN a ${rollbackRequest.version ?: 'la versión anterior'}?",
                  ok: 'Aprobar rollback', submitter: approvers.join(','))
        }
    }
    Map hosts = [dev: env.DEV_HOST, stage: env.STAGE_HOST, prod: env.PROD_HOST]
    String toArg = rollbackRequest.version ? " --to '${rollbackRequest.version}'" : ''
    if (platform?.deployPlatform == 'k8s') {
        withKubeconfig(rbEnv) {
            sh "./deploy/scripts/k8s-deploy.sh status --env '${rbEnv}' > reports/ci/rollback-before-${rbEnv}.txt 2>&1 || true"
            sh "./infra/scripts/rollback.sh rollback '${rbEnv}' --platform k8s${toArg}"
            sh "./deploy/scripts/k8s-deploy.sh status --env '${rbEnv}' > reports/ci/rollback-after-${rbEnv}.txt 2>&1 || true"
        }
    } else {
        withEnvironmentCredentials {
            sh "./infra/scripts/rollback.sh status '${rbEnv}' > reports/ci/rollback-before-${rbEnv}.txt 2>&1 || true"
            sh "./infra/scripts/rollback.sh rollback '${rbEnv}' --host '${hosts[rbEnv]}'${toArg}"
            sh "./infra/scripts/rollback.sh status '${rbEnv}' > reports/ci/rollback-after-${rbEnv}.txt 2>&1 || true"
        }
    }
    currentBuild.description = "ROLLBACK ${rbEnv} -> ${rollbackRequest.version ?: 'versión anterior'} (${platform?.deployPlatform})"
}
