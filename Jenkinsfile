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
// US-13 — Despliegue automático a dev y promoción a stage tras E2E:
//   CA1: Toda ejecución de main que publica imágenes despliega esa versión SemVer en
//        dev y verifica los healthchecks de servicios y middleware.
//   CA2: Los flujos E2E (e2e/, contrato de US-17) corren contra dev; solo si pasan
//        se promueve la MISMA versión a stage.
//   CA3: Si fallan el despliegue, los healthchecks o los E2E, stage no se toca y la
//        decisión queda en reports/ci/promotion-stage.json y en la descripción del build.
//
// Requisitos del agente: JDK 21, Node.js 20+, git, openssh-client y permisos de
// ejecución sobre ./gradlew. Credenciales: 'nexus-credentials' y 'circleguard-env-ssh'.
// =============================================================================
import groovy.json.JsonOutput

@Library('circleguard-shared-lib') _

// Contexto, detección y plan se calculan en las primeras etapas y quedan
// disponibles para los bloques `when` y `post` de las etapas posteriores.
def flow = [:]
def detection = [:]
def plan = [:]
def versionMap = [:]
// US-13: resultado de cada compuerta de entrega continua (SUCCESS | FAILURE | NOT_RUN).
def deployResults = [deployDev: 'NOT_RUN', verifyDev: 'NOT_RUN', e2eDev: 'NOT_RUN', promoteStage: 'NOT_RUN', verifyStage: 'NOT_RUN']

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
        booleanParam(
            name: 'PUBLISH_GITHUB_STATUS',
            defaultValue: true,
            description: 'Publica los estados PENDING/SUCCESS/FAILURE como Commit Status en GitHub.'
        )
    }

    environment {
        GRADLE_OPTS = '-Dorg.gradle.daemon=false'
        CI = 'true'
        // US-13: nodos de ambiente (US-05) y registro (US-11). Sobrescribibles con variables
        // globales de Jenkins (CG_DEV_HOST, CG_STAGE_HOST, CG_REGISTRY_URL) sin tocar el repo.
        DEV_HOST = "${env.CG_DEV_HOST ?: '52.15.213.209'}"
        STAGE_HOST = "${env.CG_STAGE_HOST ?: '3.17.163.44'}"
        DEPLOY_REGISTRY_URL = "${env.CG_REGISTRY_URL ?: '52.14.6.11:5000'}"
        ENV_SSH_CREDENTIALS_ID = 'circleguard-env-ssh'
        NEXUS_CREDENTIALS_ID = 'nexus-credentials'
    }

    stages {
        stage('Checkout & Context') {
            steps {
                script {
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
                    detection = detectChangedServices(forceAll: params.FORCE_FULL_BUILD as boolean)
                    plan = multibranchFlow.planPipeline(flow, detection, [
                        targetEnv: params.TARGET_ENV,
                        forceFullBuild: params.FORCE_FULL_BUILD as boolean
                    ])

                    echo pipelineUtils.formatDetectionSummary(detection)
                    echo multibranchFlow.formatPlanSummary(plan)

                    // Guarda dura CA2: si alguien solicita un despliegue no permitido
                    // (por ejemplo TARGET_ENV=prod en un PR), el build falla de inmediato.
                    if (plan.deploymentRequested && !plan.deploymentAllowed) {
                        multibranchFlow.requireDeploymentAllowed(flow, params.TARGET_ENV)
                    }

                    sh 'mkdir -p reports/ci'
                    writeFile file: 'reports/ci/change-detection.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(detection))
                    writeFile file: 'reports/ci/pipeline-plan.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(plan))
                }
            }
        }

        stage('Calculate SemVer') {
            when {
                expression { plan?.runHeavyBuild == true }
            }
            steps {
                script {
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
            }
        }

        stage('Compile & Test Backend') {
            when {
                expression { plan?.runBackendBuild == true }
            }
            steps {
                script {
                    // JaCoCo se habilita en US-10 (aún no está aplicado en build.gradle.kts).
                    String gradleCommand = pipelineUtils.buildGradleCommandForServices(
                        plan.backendServices,
                        [includeTests: true, includeJacoco: false, daemon: false]
                    )
                    echo "Servicios backend afectados (${plan.backendServices.size()}): ${plan.backendServices.join(', ')}"
                    sh "${gradleCommand}"
                }
            }
        }

        stage('Compile & Test Web') {
            when {
                expression { plan?.runMobileBuild == true }
            }
            steps {
                dir('mobile') {
                    sh 'npm ci --no-audit --no-fund'
                    sh 'npm run test -- --ci --watchAll=false'
                }
            }
        }

        stage('Validate Compose Environments') {
            when {
                expression { plan?.runHeavyBuild == true }
            }
            steps {
                script {
                    echo 'Validando archivos docker-compose para dev, stage y prod (US-08)...'
                    sh 'chmod +x deploy/compose/validate-compose.sh'
                    sh 'IMAGE_TAG="' + (versionMap.APP_VERSION ?: '0.1.0') + '" ./deploy/compose/validate-compose.sh'
                    // US-13: los scripts de despliegue/promoción se prueban también en los PR (sin Docker ni credenciales).
                    sh 'chmod +x deploy/scripts/*.sh && ./deploy/scripts/test-deploy-scripts.sh'
                }
            }
        }

        stage('Publish Images to Nexus') {
            when {
                expression { flow?.isMainBranch == true && plan?.runHeavyBuild == true }
            }
            steps {
                script {
                    String semver = versionMap.APP_VERSION ?: '0.1.0'
                    echo "Construyendo y publicando imagenes en Nexus con version semantica: ${semver} (US-11)..."
                    withCredentials([usernamePassword(
                        credentialsId: 'nexus-credentials',
                        usernameVariable: 'NEXUS_USER',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )]) {
                        sh 'chmod +x infra/scripts/publish-docker-images.sh'
                        sh """
                            REGISTRY_URL="52.14.6.11:5000" \
                            REGISTRY_USER="\${NEXUS_USER}" \
                            REGISTRY_PASSWORD="\${NEXUS_PASSWORD}" \
                            VERSION="${semver}" \
                            ./infra/scripts/publish-docker-images.sh
                        """
                    }
                }
            }
        }

        stage('Generate Release Notes & Tag') {
            when {
                expression { flow?.isMainBranch == true }
            }
            steps {
                script {
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
        stage('Deploy to dev') {
            when {
                expression { plan?.autoDeployDev == true }
            }
            steps {
                script {
                    deployResults.deployDev = 'FAILURE'
                    String version = requireReleaseVersion(versionMap)
                    echo "Desplegando automáticamente ${version} en dev (${env.DEV_HOST}) (US-13 / CA1)..."
                    withEnvironmentCredentials {
                        sh "./deploy/scripts/environment.sh deploy --env dev --version '${version}' --host '${env.DEV_HOST}'"
                    }
                    deployResults.deployDev = 'SUCCESS'
                }
            }
        }

        stage('Verify dev health') {
            when {
                expression { plan?.autoDeployDev == true }
            }
            steps {
                script {
                    deployResults.verifyDev = 'FAILURE'
                    String version = requireReleaseVersion(versionMap)
                    echo "Verificando healthchecks de los 12 contenedores de dev para ${version} (US-13 / CA1)..."
                    withEnvironmentCredentials {
                        sh "./deploy/scripts/environment.sh verify --env dev --version '${version}' --host '${env.DEV_HOST}' --report reports/ci/health-dev.json"
                    }
                    deployResults.verifyDev = 'SUCCESS'
                }
            }
        }

        stage('E2E against dev') {
            when {
                expression { plan?.autoDeployDev == true }
            }
            steps {
                script {
                    deployResults.e2eDev = 'FAILURE'
                    echo 'Ejecutando flujos E2E contra dev (US-13 / CA2; contrato e2e/ ampliable por US-17)...'
                    withEnvironmentCredentials {
                        sh "./deploy/scripts/run-e2e.sh --env dev --host '${env.DEV_HOST}'"
                    }
                    deployResults.e2eDev = 'SUCCESS'
                }
            }
        }

        stage('Promote to stage') {
            when {
                expression { plan?.promoteToStage == true }
            }
            steps {
                script {
                    String version = requireReleaseVersion(versionMap)
                    Map promotion = multibranchFlow.promotionDecision(deployResults, [version: version])
                    if (!promotion.promote) {
                        error(promotion.reason)
                    }
                    deployResults.promoteStage = 'FAILURE'
                    echo "${promotion.reason} Desplegando en stage (${env.STAGE_HOST})..."
                    withEnvironmentCredentials {
                        sh "./deploy/scripts/environment.sh deploy --env stage --version '${version}' --host '${env.STAGE_HOST}'"
                    }
                    deployResults.promoteStage = 'SUCCESS'
                }
            }
        }

        stage('Verify stage health') {
            when {
                expression { plan?.promoteToStage == true }
            }
            steps {
                script {
                    deployResults.verifyStage = 'FAILURE'
                    String version = requireReleaseVersion(versionMap)
                    withEnvironmentCredentials {
                        sh "./deploy/scripts/environment.sh verify --env stage --version '${version}' --host '${env.STAGE_HOST}' --report reports/ci/health-stage.json"
                    }
                    deployResults.verifyStage = 'SUCCESS'
                }
            }
        }

        stage('Release Gate') {
            when {
                expression { plan?.deploymentAllowed == true }
            }
            steps {
                script {
                    Map decision = multibranchFlow.requireDeploymentAllowed(flow, plan.targetEnv)
                    echo "Despliegue autorizado a '${decision.targetEnv}' (aprobación manual requerida: ${decision.requiresApproval})."
                    echo 'dev y stage se despliegan automáticamente en main (US-13); la aprobación manual hacia prod se implementa en US-31.'
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
            }
            junit allowEmptyResults: true, testResults: '**/build/test-results/test/*.xml,reports/e2e/junit.xml'
            archiveArtifacts artifacts: 'reports/**,docs/release-notes/**', allowEmptyArchive: true
        }
    }
}
