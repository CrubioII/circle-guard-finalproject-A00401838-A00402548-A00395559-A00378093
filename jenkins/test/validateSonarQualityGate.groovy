// jenkins/test/validateSonarQualityGate.groovy
// Historia de Usuario: US-10 (SCRUM-22 / SCRUM-58 / SCRUM-59 / SCRUM-60) — CA1, CA2 y CA3
// Propósito: Validación reproducible de la integración de Gradle + JaCoCo +
// SonarQube y del paso bloqueante waitForQualityGate(abortPipeline: true).

import groovy.lang.Binding
import groovy.lang.GroovyShell

File repoRoot = new File(System.getProperty('circleguard.repoRoot') ?: '.').canonicalFile
File buildGradleFile = new File(repoRoot, 'build.gradle.kts')
File jenkinsfile = new File(repoRoot, 'Jenkinsfile')
File sonarScriptFile = new File(repoRoot, 'jenkins/vars/sonarQualityGate.groovy')
File flowScriptFile = new File(repoRoot, 'jenkins/vars/multibranchFlow.groovy')
File utilsScriptFile = new File(repoRoot, 'jenkins/vars/pipelineUtils.groovy')
File detectScriptFile = new File(repoRoot, 'jenkins/vars/detectChangedServices.groovy')
File cascFile = new File(repoRoot, 'jenkins/ci/jenkins.yaml')
File sonarSetupScript = new File(repoRoot, 'jenkins/ci/setup-sonarqube-quality-gate.sh')

[buildGradleFile, jenkinsfile, sonarScriptFile, flowScriptFile, utilsScriptFile, detectScriptFile, cascFile, sonarSetupScript].each { File f ->
    assert f.exists() : "No existe el archivo requerido para US-10: ${f.path}"
}

Map mockEnv = [
    BRANCH_NAME      : 'PR-10',
    CHANGE_ID        : '10',
    CHANGE_TARGET    : 'main',
    SONAR_PROJECT_KEY: 'circleguard-monorepo'
]

List<Map> jacocoInvocations = []
List<Map> waitForQualityGateInvocations = []
String simulatedQualityGateStatus = 'OK'

Binding binding = new Binding()
binding.setVariable('env', mockEnv)
binding.setVariable('echo', { String msg -> println("[JENKINS-ECHO] ${msg}") })
binding.setVariable('error', { String msg -> throw new IllegalStateException(msg) })
binding.setVariable('jacoco', { Map args -> jacocoInvocations.add(args) })
binding.setVariable('waitForQualityGate', { Map args ->
    waitForQualityGateInvocations.add(args)
    if (args.abortPipeline == true && simulatedQualityGateStatus != 'OK') {
        throw new IllegalStateException("Pipeline aborted by waitForQualityGate(abortPipeline: true) with status ${simulatedQualityGateStatus}")
    }
    return [status: simulatedQualityGateStatus]
})

GroovyShell shell = new GroovyShell(binding)
def pipelineUtils = shell.parse(utilsScriptFile)
binding.setVariable('pipelineUtils', pipelineUtils)
def detectChangedServices = shell.parse(detectScriptFile)
def multibranchFlow = shell.parse(flowScriptFile)
def sonarQualityGate = shell.parse(sonarScriptFile)

println('=== Iniciando validacion reproducible de Gradle + JaCoCo + SonarQube (US-10) ===')

// -----------------------------------------------------------------------------
// Caso 1: build.gradle.kts integra jacoco y org.sonarqube para los 8 servicios (CA1)
// -----------------------------------------------------------------------------
String buildGradleText = buildGradleFile.getText('UTF-8')
[
    'jacoco',
    'id("org.sonarqube")',
    'apply(plugin = "jacoco")',
    'JacocoReport',
    'xml.required.set(true)',
    'reports/jacoco/test/jacocoTestReport.xml',
    'JacocoCoverageVerification',
    'BigDecimal("0.60")',
    'sonar.coverage.jacoco.xmlReportPaths',
    'validateJenkinsSonarQualityGate'
].each { String token ->
    assert buildGradleText.contains(token) : "build.gradle.kts no contiene la configuracion requerida (CA1): ${token}"
}
println('[OK] Caso 1: build.gradle.kts integra jacoco y org.sonarqube con reportes XML para los 8 servicios.')

// -----------------------------------------------------------------------------
// Caso 2: rutas XML de JaCoCo para los 8 microservicios y servicios núcleo (CA1)
// -----------------------------------------------------------------------------
Map defaultConfig = sonarQualityGate.call()
assert defaultConfig.allBackendServices.size() == 8
assert defaultConfig.coreBackendServices.size() == 5
assert defaultConfig.minCoreCoverage == 60.0d
assert defaultConfig.xmlReportPaths.size() == 8
assert defaultConfig.xmlReportPaths.every { String p -> p.endsWith('/build/reports/jacoco/test/jacocoTestReport.xml') }
println('[OK] Caso 2: rutas XML de JaCoCo resueltas para los 8 microservicios y 5 servicios nucleo.')

// -----------------------------------------------------------------------------
// Caso 3: comando Gradle para SonarQube incluye rutas XML y clave de proyecto (CA2)
// -----------------------------------------------------------------------------
String sonarCmd = sonarQualityGate.buildSonarGradleCommand(
    ['circleguard-auth-service', 'circleguard-identity-service'],
    [projectKey: 'circleguard-monorepo', skipTests: true, daemon: false]
)
assert sonarCmd.startsWith('./gradlew sonar')
assert sonarCmd.contains('-Dsonar.projectKey=circleguard-monorepo')
assert sonarCmd.contains('services/circleguard-auth-service/build/reports/jacoco/test/jacocoTestReport.xml')
assert sonarCmd.contains('services/circleguard-identity-service/build/reports/jacoco/test/jacocoTestReport.xml')
assert sonarCmd.contains('-x test')
assert sonarCmd.contains('--no-daemon --stacktrace')

String compileCmd = pipelineUtils.buildGradleCommandForServices(
    ['circleguard-auth-service'],
    [includeTests: true, includeJacoco: true, daemon: false]
)
assert compileCmd.contains(':services:circleguard-auth-service:assemble')
assert compileCmd.contains(':services:circleguard-auth-service:test')
assert compileCmd.contains(':services:circleguard-auth-service:jacocoTestReport')
println('[OK] Caso 3: comandos Gradle de compilacion/JaCoCo y de SonarQube generados correctamente.')

// -----------------------------------------------------------------------------
// Caso 4: parseo de reportes XML de JaCoCo y lectura desde el workspace (CA1 + CA2)
// -----------------------------------------------------------------------------
String sampleXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<report name="circleguard-auth-service">
  <package name="com/circleguard/auth">
    <counter type="LINE" missed="5" covered="20"/>
  </package>
  <counter type="INSTRUCTION" missed="20" covered="80"/>
  <counter type="LINE" missed="25" covered="75"/>
</report>'''

Map parsedMetrics = sonarQualityGate.parseJacocoXmlCounters(sampleXml)
assert parsedMetrics.found == true
assert parsedMetrics.missedLines == 25
assert parsedMetrics.coveredLines == 75
assert parsedMetrics.totalLines == 100
assert parsedMetrics.lineCoveragePercent == 75.0d
assert parsedMetrics.instructionCoveragePercent == 80.0d

File tempWorkspace = File.createTempDir('us10-jacoco-workspace-', '')
try {
    File authXml = new File(tempWorkspace, 'services/circleguard-auth-service/build/reports/jacoco/test/jacocoTestReport.xml')
    authXml.parentFile.mkdirs()
    authXml.setText(sampleXml, 'UTF-8')

    Map collected = sonarQualityGate.collectServiceCoverage(['circleguard-auth-service', 'circleguard-file-service'], tempWorkspace.absolutePath)
    assert collected['circleguard-auth-service'].reportExists == true
    assert collected['circleguard-auth-service'].isCoreService == true
    assert collected['circleguard-auth-service'].lineCoveragePercent == 75.0d
    assert collected['circleguard-file-service'].reportExists == false
    assert collected['circleguard-file-service'].isCoreService == false
} finally {
    tempWorkspace.deleteDir()
}
println('[OK] Caso 4: parseo de contadores XML de JaCoCo (LINE e INSTRUCTION) verificado.')

// -----------------------------------------------------------------------------
// Caso 5: publicación de reportes JaCoCo en la interfaz de Jenkins (CA2)
// -----------------------------------------------------------------------------
Map pubResult = sonarQualityGate.publishJacocoReports(services: ['circleguard-auth-service'])
assert pubResult.publishedByPlugin == true
assert jacocoInvocations.size() == 1
assert jacocoInvocations[0].execPattern == '**/build/jacoco/*.exec'
println('[OK] Caso 5: reportes JaCoCo publicados en la interfaz de Jenkins.')

// -----------------------------------------------------------------------------
// Caso 6: el plan del pipeline activa SonarQube Analysis y Quality Gate en builds backend (CA2 + CA3)
// -----------------------------------------------------------------------------
Map prContext = multibranchFlow.collectContext([branchName: 'PR-10', changeId: '10', changeTarget: 'main'])
Map backendDetection = detectChangedServices.call([
    changedFilesOverride: ['services/circleguard-auth-service/src/main/java/com/circleguard/auth/AuthApp.java']
])
Map planWithSonar = multibranchFlow.planPipeline(prContext, backendDetection, [targetEnv: 'none'])
assert planWithSonar.runBackendBuild == true
assert planWithSonar.runSonarAnalysis == true
assert planWithSonar.runQualityGate == true
assert planWithSonar.stages.contains('SonarQube Analysis')
assert planWithSonar.stages.contains('Quality Gate')

Map docsDetection = detectChangedServices.call([changedFilesOverride: ['README.md']])
Map docsPlan = multibranchFlow.planPipeline(prContext, docsDetection, [targetEnv: 'none'])
assert docsPlan.runSonarAnalysis == false
assert docsPlan.runQualityGate == false
assert !docsPlan.stages.contains('SonarQube Analysis')
println('[OK] Caso 6: multibranchFlow planifica SonarQube Analysis y Quality Gate cuando cambia backend.')

// -----------------------------------------------------------------------------
// Caso 7: Quality Gate aprueba cuando SonarQube devuelve OK y cobertura núcleo >= 60% (CA3)
// -----------------------------------------------------------------------------
simulatedQualityGateStatus = 'OK'
Map gatePass = sonarQualityGate.enforceQualityGate([
    minCoreCoverage         : 60.0d,
    enforceLocalCoreCoverage: true,
    coverageByService       : [
        'circleguard-auth-service'    : [lineCoveragePercent: 78.5d, reportExists: true],
        'circleguard-identity-service': [lineCoveragePercent: 64.0d, reportExists: true],
        'circleguard-file-service'    : [lineCoveragePercent: 40.0d, reportExists: true] // no es servicio núcleo
    ]
])
assert gatePass.passed == true
assert gatePass.sonarStatus == 'OK'
assert waitForQualityGateInvocations.last().abortPipeline == true
println('[OK] Caso 7: Quality Gate aprueba con SonarQube=OK y servicios nucleo >= 60%.')

// -----------------------------------------------------------------------------
// Caso 8: waitForQualityGate(abortPipeline: true) bloquea el pipeline cuando SonarQube devuelve ERROR (CA3)
// -----------------------------------------------------------------------------
simulatedQualityGateStatus = 'ERROR'
boolean blockedBySonar = false
try {
    sonarQualityGate.enforceQualityGate([minCoreCoverage: 60.0d])
} catch (IllegalStateException ex) {
    blockedBySonar = ex.message.contains('waitForQualityGate(abortPipeline: true)')
}
assert blockedBySonar : 'El pipeline debe abortar inmediatamente cuando waitForQualityGate reporta ERROR'
simulatedQualityGateStatus = 'OK'
println('[OK] Caso 8: waitForQualityGate(abortPipeline: true) bloquea inmediatamente el pipeline ante fallo en SonarQube.')

// -----------------------------------------------------------------------------
// Caso 9: el Quality Gate bloquea si un servicio núcleo tiene cobertura < 60% (CA3)
// -----------------------------------------------------------------------------
boolean blockedByLowCoverage = false
try {
    sonarQualityGate.enforceQualityGate([
        minCoreCoverage         : 60.0d,
        enforceLocalCoreCoverage: true,
        coverageByService       : [
            'circleguard-auth-service'     : [lineCoveragePercent: 82.0d, reportExists: true],
            'circleguard-promotion-service': [lineCoveragePercent: 45.5d, reportExists: true]
        ]
    ])
} catch (IllegalStateException ex) {
    blockedByLowCoverage = ex.message.contains('circleguard-promotion-service=45.5%')
}
assert blockedByLowCoverage : 'El pipeline debe abortar cuando un servicio núcleo cae por debajo de 60% de cobertura'
println('[OK] Caso 9: bloqueo verificado cuando un servicio nucleo incumple el umbral de cobertura (< 60%).')

// -----------------------------------------------------------------------------
// Caso 10: el Jenkinsfile integra JaCoCo, SonarQube Analysis y Quality Gate (CA2 + CA3)
// -----------------------------------------------------------------------------
String jenkinsfileText = jenkinsfile.getText('UTF-8')
[
    'includeJacoco: true',
    "sonarQualityGate = load 'jenkins/vars/sonarQualityGate.groovy'",
    'sonarQualityGate.collectServiceCoverage(',
    "stage('SonarQube Analysis')",
    "withSonarQubeEnv('SonarQube')",
    'sonarQualityGate.buildSonarGradleCommand(',
    "stage('Quality Gate')",
    'sonarQualityGate.enforceQualityGate(',
    'services/*/build/reports/jacoco/test/**'
].each { String fragment ->
    assert jenkinsfileText.contains(fragment) : "El Jenkinsfile no contiene el bloque requerido por US-10: ${fragment}"
}
// La librería global no se fija a una rama: main nunca debe depender de una rama de feature.
assert jenkinsfileText.contains("@Library('circleguard-shared-lib') _") :
    "El Jenkinsfile debe cargar circleguard-shared-lib sin fijar una rama (@Library('circleguard-shared-lib') _)."
// El Quality Gate bloquea ANTES de publicar imágenes y desplegar (si no, no protegería nada).
List<Integer> gateOrder = ["stage('Coverage Gate", "stage('SonarQube Analysis')", "stage('Quality Gate')",
                           "stage('Publish Images to Nexus')", "stage('Deploy to dev')"].collect { jenkinsfileText.indexOf(it) }
assert gateOrder.every { it >= 0 } && gateOrder == gateOrder.sort(false) :
    "El Quality Gate debe ir tras el Coverage Gate y antes de publicar y desplegar: ${gateOrder}"
// JaCoCo se publica una sola vez, en post { always } (US-31 / US-32).
assert jenkinsfileText.count('jacoco(') == 1 : 'El reporte JaCoCo debe publicarse una sola vez (post { always }).'
println('[OK] Caso 10: Jenkinsfile integra JaCoCo, withSonarQubeEnv y la etapa Quality Gate antes de publicar y desplegar.')

// -----------------------------------------------------------------------------
// Caso 11: JCasC declara sonarGlobalConfiguration con credencial sonar-token (CA2 + CA3)
// -----------------------------------------------------------------------------
String cascText = cascFile.getText('UTF-8')
[
    'sonarGlobalConfiguration:',
    'name: "SonarQube"',
    'credentialsId: "sonar-token"',
    'SONAR_PROJECT_KEY'
].each { String required ->
    assert cascText.contains(required) : "jenkins/ci/jenkins.yaml no contiene la configuracion de SonarQube: ${required}"
}
println('[OK] Caso 11: JCasC declara la instalacion SonarQube y la credencial sonar-token.')

// -----------------------------------------------------------------------------
// Caso 12: validacion del script de Quality Gate y webhook bidireccional (SCRUM-58)
// -----------------------------------------------------------------------------
Process sonarScriptTest = new ProcessBuilder('bash', 'jenkins/test/validateSonarWebhookScript.sh')
    .directory(repoRoot)
    .redirectErrorStream(true)
    .start()
String sonarScriptOutput = sonarScriptTest.inputStream.getText('UTF-8')
int sonarScriptExit = sonarScriptTest.waitFor()
println(sonarScriptOutput.readLines().collect { "  ${it}" }.join('\n'))
assert sonarScriptExit == 0 : 'La validacion del script de SonarQube Quality Gate y webhook fallo'
assert sonarScriptOutput.contains('VALIDACION DE SONARQUBE QUALITY GATE Y WEBHOOK COMPLETADA')
println('[OK] Caso 12: script idempotente de Quality Gate (>= 60%) y webhook /sonarqube-webhook/ validado.')

println('=== TODAS LAS PRUEBAS DE GRADLE + JACOCO + SONARQUBE (US-10) PASARON EXITOSAMENTE ===')
