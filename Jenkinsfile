#!/usr/bin/env groovy
// =============================================================================
// Jenkinsfile raíz — CircleGuard Multibranch Pipeline
// Historias de Usuario:
//   - US-30 (SCRUM-113): Jenkins Multibranch que consume la Shared Library (US-09).
//   - US-10 (SCRUM-22):  Compilación Gradle, cobertura JaCoCo y Quality Gate
//                        bloqueante en SonarQube (waitForQualityGate abortPipeline: true).
//
// Criterios de aceptación cubiertos:
//   US-30 CA1-CA3: Carga 'circleguard-shared-lib', separa PR vs. main, bloquea
//                  despliegues desde PR y publica estados en GitHub.
//   US-10 CA1-CA3: Ejecuta jacocoTestReport en los servicios afectados, publica
//                  reportes JaCoCo en Jenkins, envía métricas a SonarQube y
//                  bloquea el pipeline con waitForQualityGate(abortPipeline: true)
//                  si falla el Quality Gate (>= 60% cobertura en servicios núcleo).
// =============================================================================
import groovy.json.JsonOutput

@Library('circleguard-shared-lib@feature/US-10-jacoco-sonarqube-quality-gate') _

def flow = [:]
def detection = [:]
def plan = [:]
def coverageByService = [:]

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
        booleanParam(
            name: 'ENABLE_SONARQUBE_GATE',
            defaultValue: true,
            description: 'Ejecuta el análisis estático con SonarQube y el bloqueo waitForQualityGate(abortPipeline: true).'
        )
    }

    environment {
        GRADLE_OPTS = '-Dorg.gradle.daemon=false'
        CI = 'true'
        SONAR_PROJECT_KEY = 'circleguard-monorepo'
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
                        forceFullBuild: params.FORCE_FULL_BUILD as boolean,
                        enableSonar: params.ENABLE_SONARQUBE_GATE as boolean
                    ])

                    echo pipelineUtils.formatDetectionSummary(detection)
                    echo multibranchFlow.formatPlanSummary(plan)

                    if (plan.deploymentRequested && !plan.deploymentAllowed) {
                        multibranchFlow.requireDeploymentAllowed(flow, params.TARGET_ENV)
                    }

                    sh 'mkdir -p reports/ci'
                    writeFile file: 'reports/ci/change-detection.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(detection))
                    writeFile file: 'reports/ci/pipeline-plan.json', text: JsonOutput.prettyPrint(JsonOutput.toJson(plan))
                }
            }
        }

        stage('Compile & Test Backend') {
            when {
                expression { plan?.runBackendBuild == true }
            }
            steps {
                script {
                    String gradleCommand = pipelineUtils.buildGradleCommandForServices(
                        plan.backendServices,
                        [includeTests: true, includeJacoco: true, daemon: false]
                    )
                    echo "Servicios backend afectados (${plan.backendServices.size()}): ${plan.backendServices.join(', ')}"
                    sh "${gradleCommand}"

                    coverageByService = sonarQualityGate.collectServiceCoverage(plan.backendServices, '.')
                    Map jacocoPublication = sonarQualityGate.publishJacocoReports(services: plan.backendServices)
                    writeFile(
                        file: 'reports/ci/jacoco-coverage.json',
                        text: JsonOutput.prettyPrint(JsonOutput.toJson([
                            publication      : jacocoPublication,
                            coverageByService: coverageByService
                        ]))
                    )
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

        stage('SonarQube Analysis') {
            when {
                expression { plan?.runSonarAnalysis == true }
            }
            steps {
                script {
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

        stage('Quality Gate') {
            when {
                expression { plan?.runQualityGate == true }
            }
            steps {
                script {
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
            archiveArtifacts artifacts: 'reports/ci/**,services/*/build/reports/jacoco/test/**', allowEmptyArchive: true
        }
    }
}
