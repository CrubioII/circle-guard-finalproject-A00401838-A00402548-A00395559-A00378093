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
// Requisitos del agente: JDK 21, Node.js 20+ (solo si cambia mobile/), git y
// permisos de ejecución sobre ./gradlew.
// =============================================================================
import groovy.json.JsonOutput

@Library('circleguard-shared-lib') _

// Contexto, detección y plan se calculan en las primeras etapas y quedan
// disponibles para los bloques `when` y `post` de las etapas posteriores.
def flow = [:]
def detection = [:]
def plan = [:]
def versionMap = [:]

// US-31: servicios núcleo con umbral mínimo de 60% de cobertura de líneas (gateway y complementarios en US-32).
List<String> CORE_COVERAGE_SERVICES = [
    'circleguard-auth-service',
    'circleguard-identity-service',
    'circleguard-promotion-service',
    'circleguard-form-service'
]

pipeline {
    agent any

    options {
        timestamps()
        ansiColor('xterm')
        timeout(time: 45, unit: 'MINUTES')
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
                    // US-31: JaCoCo aplicado en build.gradle.kts; cada servicio genera su reporte XML/HTML.
                    String gradleCommand = pipelineUtils.buildGradleCommandForServices(
                        plan.backendServices,
                        [includeTests: true, includeJacoco: true, daemon: false]
                    )
                    echo "Servicios backend afectados (${plan.backendServices.size()}): ${plan.backendServices.join(', ')}"
                    sh "${gradleCommand}"
                }
            }
        }

        stage('Coverage Gate (servicios núcleo)') {
            when {
                expression { plan?.runBackendBuild == true && plan.backendServices.any { it in CORE_COVERAGE_SERVICES } }
            }
            steps {
                script {
                    // US-31 / CA1: falla el build si auth, identity, promotion o form bajan del 60% de líneas.
                    List<String> coreServices = plan.backendServices.findAll { it in CORE_COVERAGE_SERVICES }
                    String tasks = coreServices.collect { ":services:${it}:jacocoTestCoverageVerification" }.join(' ')
                    echo "Verificando cobertura de líneas >= 60% en: ${coreServices.join(', ')}"
                    sh "./gradlew ${tasks} --no-daemon --stacktrace"
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

        stage('Release Gate') {
            when {
                expression { plan?.deploymentAllowed == true }
            }
            steps {
                script {
                    Map decision = multibranchFlow.requireDeploymentAllowed(flow, plan.targetEnv)
                    echo "Despliegue autorizado a '${decision.targetEnv}' (aprobación manual requerida: ${decision.requiresApproval})."
                    echo 'La promoción material dev -> stage -> prod y el bloque input de aprobación se implementan en US-13.'
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
                    publishBuildStatus(state: 'FAILURE', flow: flow, description: 'CircleGuard CI falló')
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
        always {
            junit allowEmptyResults: true, testResults: '**/build/test-results/test/*.xml'
            script {
                // US-31 / CA3: publica la cobertura JaCoCo (tendencia + detalle por clase) y archiva los reportes HTML/XML.
                if (sh(returnStatus: true, script: 'ls services/*/build/jacoco/test.exec >/dev/null 2>&1') == 0) {
                    jacoco(
                        execPattern: 'services/*/build/jacoco/test.exec',
                        classPattern: 'services/*/build/classes/java/main',
                        sourcePattern: 'services/*/src/main/java',
                        exclusionPattern: '**/*Application.class'
                    )
                }
            }
            archiveArtifacts artifacts: 'reports/ci/**,docs/release-notes/**,services/*/build/reports/jacoco/test/**', allowEmptyArchive: true
        }
    }
}
