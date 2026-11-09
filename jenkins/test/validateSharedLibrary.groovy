// jenkins/test/validateSharedLibrary.groovy
// Historia de Usuario: US-09 (SCRUM-21 / SCRUM-55) - CA3
// Propósito: Suite de validación reproducible para comprobar el funcionamiento
// de la Shared Library (detectChangedServices y pipelineUtils) simulando un contexto de pipeline Jenkins.

import groovy.lang.GroovyShell
import groovy.lang.Binding

File repoRoot = new File(System.getProperty('circleguard.repoRoot') ?: '.').canonicalFile
File detectScriptFile = new File(repoRoot, 'jenkins/vars/detectChangedServices.groovy')
File utilsScriptFile  = new File(repoRoot, 'jenkins/vars/pipelineUtils.groovy')

assert detectScriptFile.exists() : "No existe ${detectScriptFile.path}"
assert utilsScriptFile.exists()  : "No existe ${utilsScriptFile.path}"

// Simular el contexto de variables globales de un pipeline de Jenkins (env, echo, sh)
Map mockEnv = [
    BRANCH_NAME  : 'feature/US-09-jenkins-shared-library',
    CHANGE_ID    : '2',
    CHANGE_TARGET: 'main'
]

List<String> mockGitDiffLines = [
    'services/circleguard-auth-service/src/main/java/com/circleguard/auth/AuthApp.java',
    'mobile/App.tsx'
]

Binding binding = new Binding()
binding.setVariable('env', mockEnv)
binding.setVariable('echo', { String msg -> println("[JENKINS-ECHO] ${msg}") })
binding.setVariable('sh', { Map args ->
    return mockGitDiffLines.join('\n')
})

GroovyShell shell = new GroovyShell(binding)
def detectChangedServices = shell.parse(detectScriptFile)
def pipelineUtils = shell.parse(utilsScriptFile)

println("=== Iniciando validacion reproducible de la Shared Library (US-09) ===")

// -------------------------------------------------------------------------
// Caso 1: Invocación directa desde pipeline simulando un PR con git diff (CA2 y CA3)
// -------------------------------------------------------------------------
Map prResult = detectChangedServices.call([:])
assert prResult.backendServices == ['circleguard-auth-service'] : "Esperaba solo auth-service, obtuvo: ${prResult.backendServices}"
assert prResult.coreServices == ['circleguard-auth-service']
assert prResult.mobileChanged == true
assert prResult.sharedChanged == false
assert prResult.fullBuild == false
assert prResult.skipCiBuild == false
assert prResult.gradleTestTasks == [':services:circleguard-auth-service:test']
assert prResult.servicePorts['circleguard-auth-service'] == 8180
println("[OK] Caso 1: Deteccion en PR con cambio en 1 microservicio + mobile validada.")

// -------------------------------------------------------------------------
// Caso 2: Cambio en múltiples microservicios backend específicos (CA2)
// -------------------------------------------------------------------------
Map multiResult = detectChangedServices.call([
    changedFilesOverride: [
        'services/circleguard-gateway-service/build.gradle.kts',
        'services/circleguard-identity-service/src/main/resources/application.yml',
        'services/circleguard-dashboard-service/src/test/java/DashboardTest.java'
    ]
])
assert multiResult.backendServices == [
    'circleguard-identity-service',
    'circleguard-gateway-service',
    'circleguard-dashboard-service'
]
assert multiResult.coreServices == [
    'circleguard-identity-service',
    'circleguard-gateway-service'
]
assert multiResult.mobileChanged == false
assert multiResult.sharedChanged == false
assert multiResult.fullBuild == false
println("[OK] Caso 2: Deteccion de multiples microservicios especificos y filtrado de coreServices validada.")

// -------------------------------------------------------------------------
// Caso 3: Cambio compartido en la raíz (build.gradle.kts) que impacta todos los 8 servicios (CA2)
// -------------------------------------------------------------------------
Map sharedResult = detectChangedServices.call([
    changedFilesOverride: [
        'build.gradle.kts'
    ]
])
assert sharedResult.sharedChanged == true
assert sharedResult.fullBuild == true
assert sharedResult.backendServices.size() == 8 : "Un cambio en build.gradle.kts debe activar los 8 microservicios"
assert sharedResult.coreServices.size() == 5
println("[OK] Caso 3: Cambio compartido (build.gradle.kts) activa correctamente los 8 microservicios.")

// -------------------------------------------------------------------------
// Caso 4: Cambio exclusivo en documentación (docs/ o .github/) activa skipCiBuild
// -------------------------------------------------------------------------
Map docsResult = detectChangedServices.call([
    changedFilesOverride: [
        'docs/agil/BRANCHING_STRATEGY.md',
        '.github/pull_request_template.md'
    ]
])
assert docsResult.docsOnly == true
assert docsResult.skipCiBuild == true
assert docsResult.backendServices.isEmpty()
assert docsResult.mobileChanged == false
println("[OK] Caso 4: Cambios exclusivos de documentacion detectados con skipCiBuild=true.")

// -------------------------------------------------------------------------
// Caso 4b (US-34): Cambios en la suite E2E (e2e/) activan el cliente web para ejecutar Playwright
// -------------------------------------------------------------------------
Map e2eResult = detectChangedServices.call([
    changedFilesOverride: [
        'e2e/playwright.config.ts',
        'e2e/tests/flows/login.spec.ts'
    ]
])
assert e2eResult.mobileChanged == true
assert e2eResult.skipCiBuild == false
assert e2eResult.backendServices.isEmpty()
assert e2eResult.allComponents == ['mobile']
println("[OK] Caso 4b: Cambios en e2e/ activan la etapa web y la ejecucion E2E de Playwright.")

// -------------------------------------------------------------------------
// Caso 5: Ejecución forzada (forceAll: true) para releases completos
// -------------------------------------------------------------------------
Map forceAllResult = detectChangedServices.call([
    changedFilesOverride: ['README.md'],
    forceAll: true
])
assert forceAllResult.fullBuild == true
assert forceAllResult.skipCiBuild == false
assert forceAllResult.backendServices.size() == 8
assert forceAllResult.mobileChanged == true
println("[OK] Caso 5: Bandera forceAll=true incluye los 8 microservicios y mobile.")

// -------------------------------------------------------------------------
// Caso 6: Validación de utilidades comunes (pipelineUtils)
// -------------------------------------------------------------------------
Map ctxPr = pipelineUtils.call([branchName: 'feature/US-09', changeId: '10', changeTarget: 'main'])
assert ctxPr.isPullRequest == true
assert ctxPr.isMainBranch == false
assert ctxPr.canDeployProd == false

Map ctxMain = pipelineUtils.call([branchName: 'main', changeId: ''])
assert ctxMain.isPullRequest == false
assert ctxMain.isMainBranch == true
assert ctxMain.canDeployProd == true

String gradleCmd = pipelineUtils.buildGradleCommandForServices(['circleguard-auth-service', 'circleguard-gateway-service'])
assert gradleCmd == './gradlew :services:circleguard-auth-service:assemble :services:circleguard-auth-service:test :services:circleguard-auth-service:jacocoTestReport :services:circleguard-gateway-service:assemble :services:circleguard-gateway-service:test :services:circleguard-gateway-service:jacocoTestReport --no-daemon --stacktrace'

assert pipelineUtils.isValidSemVerTag('1.2.0') == true
assert pipelineUtils.isValidSemVerTag('v1.2.0-rc.1') == true
assert pipelineUtils.isValidSemVerTag('latest') == false

String imgRef = pipelineUtils.formatDockerImageRef('nexus.circleguard.internal:5000/', 'circleguard-auth-service', 'v1.3.0')
assert imgRef == 'nexus.circleguard.internal:5000/circleguard/auth-service:1.3.0'

boolean rejectedLatest = false
try {
    pipelineUtils.formatDockerImageRef('nexus.circleguard.internal:5000', 'circleguard-auth-service', 'latest')
} catch (IllegalArgumentException expected) {
    rejectedLatest = true
}
assert rejectedLatest : "formatDockerImageRef debe rechazar explicitamente el tag ':latest'"

println("[OK] Caso 6: Utilidades de pipelineUtils (contexto PR/main, comandos Gradle y bloqueo de :latest) validadas.")
println(pipelineUtils.formatDetectionSummary(prResult))
println("=== TODAS LAS PRUEBAS DE LA SHARED LIBRARY PASARON EXITOSAMENTE ===")
