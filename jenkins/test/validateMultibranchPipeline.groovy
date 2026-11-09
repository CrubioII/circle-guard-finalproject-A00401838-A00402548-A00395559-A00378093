// jenkins/test/validateMultibranchPipeline.groovy
// Historia de Usuario: US-30 (SCRUM-113 / SCRUM-56 / SCRUM-57) — CA1, CA2 y CA3
// Propósito: Validación reproducible del Jenkinsfile Multibranch, del flujo
// PR/main (bloqueo de despliegues desde PR), de la publicación de estados en
// GitHub y de la configuración JCasC del job y del webhook.

import groovy.lang.Binding
import groovy.lang.GroovyShell

File repoRoot = new File(System.getProperty('circleguard.repoRoot') ?: '.').canonicalFile
File jenkinsfile = new File(repoRoot, 'Jenkinsfile')
File flowScriptFile = new File(repoRoot, 'jenkins/vars/multibranchFlow.groovy')
File statusScriptFile = new File(repoRoot, 'jenkins/vars/publishBuildStatus.groovy')
File detectScriptFile = new File(repoRoot, 'jenkins/vars/detectChangedServices.groovy')
File utilsScriptFile = new File(repoRoot, 'jenkins/vars/pipelineUtils.groovy')
File cascFile = new File(repoRoot, 'jenkins/ci/jenkins.yaml')
File webhookScript = new File(repoRoot, 'jenkins/ci/setup-github-webhook.sh')

// En Windows CreateProcess resuelve 'bash' al lanzador de WSL (System32) antes que al PATH;
// se prefiere $BASH_EXE o Git Bash. En Linux/Jenkins siempre es 'bash'.
boolean isWindowsHost = System.getProperty('os.name').toLowerCase().contains('windows')
String bashExecutable = System.getenv('BASH_EXE') ?:
    (['C:/Program Files/Git/bin/bash.exe', 'C:/Program Files (x86)/Git/bin/bash.exe']
        .find { String candidate -> isWindowsHost && new File(candidate).exists() } ?: 'bash')

[jenkinsfile, flowScriptFile, statusScriptFile, detectScriptFile, utilsScriptFile, cascFile, webhookScript].each { File file ->
    assert file.exists() : "No existe el archivo requerido: ${file.path}"
}

// -----------------------------------------------------------------------------
// Contexto simulado de Jenkins (env, echo, sh, error, githubNotify)
// -----------------------------------------------------------------------------
Map mockEnv = [
    BRANCH_NAME              : 'PR-42',
    CHANGE_ID                : '42',
    CHANGE_TARGET            : 'main',
    CHANGE_BRANCH            : 'feature/US-30-jenkins-multibranch',
    GIT_URL                  : 'https://github.com/CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093.git',
    GIT_COMMIT               : 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678',
    BUILD_URL                : 'https://ci.circleguard.example/job/circleguard-monorepo/job/PR-42/1/'
]

List<String> mockGitDiffLines = [
    'services/circleguard-auth-service/src/main/java/com/circleguard/auth/AuthApp.java',
    'mobile/App.tsx'
]

List<Map> notifiedStatuses = []

Binding binding = new Binding()
binding.setVariable('env', mockEnv)
binding.setVariable('echo', { String message -> println("[JENKINS-ECHO] ${message}") })
binding.setVariable('sh', { Map ignored -> mockGitDiffLines.join('\n') })
binding.setVariable('error', { String message -> throw new IllegalStateException(message) })
binding.setVariable('githubNotify', { Map arguments -> notifiedStatuses.add(arguments) })

GroovyShell shell = new GroovyShell(binding)
def pipelineUtils = shell.parse(utilsScriptFile)
binding.setVariable('pipelineUtils', pipelineUtils)

def detectChangedServices = shell.parse(detectScriptFile)
def multibranchFlow = shell.parse(flowScriptFile)
def publishBuildStatus = shell.parse(statusScriptFile)
binding.setVariable('multibranchFlow', multibranchFlow)
binding.setVariable('publishBuildStatus', publishBuildStatus)

println('=== Iniciando validacion reproducible del Multibranch Pipeline (US-30) ===')

// -----------------------------------------------------------------------------
// Caso 1: contexto de Pull Request y detección selectiva (CA1 + CA2)
// -----------------------------------------------------------------------------
Map prContext = multibranchFlow.collectContext([
    branchName  : 'PR-42',
    changeId    : '42',
    changeTarget: 'main',
    changeBranch: 'feature/US-30-jenkins-multibranch'
])
assert prContext.isPullRequest == true
assert prContext.isMainBranch == false
assert prContext.canDeployProd == false
assert prContext.statusContext == 'continuous-integration/jenkins/pr-head'

Map prDetection = detectChangedServices.call([
    changedFilesOverride: [
        'services/circleguard-auth-service/src/main/java/com/circleguard/auth/AuthApp.java',
        'mobile/App.tsx'
    ]
])
Map prPlan = multibranchFlow.planPipeline(prContext, prDetection, [targetEnv: 'none'])
assert prPlan.runBackendBuild == true
assert prPlan.runMobileBuild == true
assert prPlan.deploymentRequested == false
assert prPlan.deploymentAllowed == false
assert prPlan.stages.contains('Compile & Test Backend')
assert prPlan.stages.contains('Compile & Test Web')
assert prPlan.stages.contains('E2E Playwright') // US-34: los cambios en el cliente web ejecutan Playwright
assert !prPlan.stages.contains('Release Gate')
println('[OK] Caso 1: PR detecta backend + mobile y no solicita despliegue.')

// -----------------------------------------------------------------------------
// Caso 2: un PR no puede desplegar a ningún ambiente; prod se rechaza (CA2)
// -----------------------------------------------------------------------------
['dev', 'stage', 'prod'].each { String targetEnv ->
    Map plan = multibranchFlow.planPipeline(
        prContext,
        detectChangedServices.call([changedFilesOverride: ['services/circleguard-auth-service/build.gradle.kts']]),
        [targetEnv: targetEnv]
    )
    assert plan.deploymentRequested == true
    assert plan.deploymentAllowed == false : "Un PR no debe poder desplegar a ${targetEnv}"
    assert !plan.stages.contains('Release Gate') : "El PR no debe ejecutar Release Gate para ${targetEnv}"
}

Map prodPlanOnPr = multibranchFlow.planPipeline(prContext, prDetection, [targetEnv: 'prod'])
assert prodPlanOnPr.deploymentReason.contains('Pull Request') : 'La razón debe explicar que un PR no despliega'

boolean rejected = false
try {
    multibranchFlow.requireDeploymentAllowed(prContext, 'prod')
} catch (IllegalStateException expected) {
    rejected = expected.message.contains('Despliegue rechazado')
}
assert rejected : 'requireDeploymentAllowed debe abortar el build ante un PR que intenta desplegar a prod'
println('[OK] Caso 2: PR bloqueado para dev/stage/prod y requireDeploymentAllowed aborta prod.')

// -----------------------------------------------------------------------------
// Caso 3: main puede desplegar con las banderas correctas (CA2)
// -----------------------------------------------------------------------------
Map mainContext = multibranchFlow.collectContext([branchName: 'main', changeId: ''])
assert mainContext.isMainBranch == true
assert mainContext.canDeployProd == true
assert mainContext.statusContext == 'continuous-integration/jenkins/main'

Map mainDevPlan = multibranchFlow.planPipeline(mainContext, prDetection, [targetEnv: 'dev'])
assert mainDevPlan.deploymentAllowed == true
assert mainDevPlan.deploymentRequiresApproval == false
assert mainDevPlan.stages.contains('Release Gate')

Map mainProdPlan = multibranchFlow.planPipeline(mainContext, prDetection, [targetEnv: 'prod'])
assert mainProdPlan.deploymentAllowed == true
assert mainProdPlan.deploymentRequiresApproval == true
assert mainProdPlan.stages.contains('Release Gate')
println('[OK] Caso 3: main habilita dev y exige aprobacion para prod.')

// -----------------------------------------------------------------------------
// Caso 4: ramas distintas de main no despliegan (CA2)
// -----------------------------------------------------------------------------
Map featureContext = multibranchFlow.collectContext([branchName: 'feature/US-30-jenkins-multibranch', changeId: ''])
assert featureContext.isMainBranch == false
Map featureProdPlan = multibranchFlow.planPipeline(featureContext, prDetection, [targetEnv: 'prod'])
assert featureProdPlan.deploymentAllowed == false
assert featureProdPlan.deploymentReason.contains('solo la rama main')
println('[OK] Caso 4: una rama feature no puede desplegar a prod.')

// -----------------------------------------------------------------------------
// Caso 5: PR solo de documentación omite el build pesado (CA2)
// -----------------------------------------------------------------------------
Map docsDetection = detectChangedServices.call([
    changedFilesOverride: ['docs/agil/JENKINS_MULTIBRANCH_US30.md', '.github/pull_request_template.md']
])
assert docsDetection.skipCiBuild == true
Map docsPlan = multibranchFlow.planPipeline(mainContext, docsDetection, [targetEnv: 'none'])
assert docsPlan.runHeavyBuild == false
assert docsPlan.runBackendBuild == false
assert docsPlan.runMobileBuild == false
assert docsPlan.stages == ['Checkout & Context', 'Detect Changed Components']
println('[OK] Caso 5: PR de documentación omite compilación y solo ejecuta detección.')

// -----------------------------------------------------------------------------
// Caso 6: FORCE_FULL_BUILD activa 8 servicios + mobile (CA2)
// -----------------------------------------------------------------------------
Map forcedDetection = detectChangedServices.call([changedFilesOverride: ['README.md'], forceAll: true])
Map forcedPlan = multibranchFlow.planPipeline(mainContext, forcedDetection, [targetEnv: 'none', forceFullBuild: true])
assert forcedPlan.fullBuild == true
assert forcedPlan.backendServices.size() == 8
assert forcedPlan.mobileChanged == true
assert forcedPlan.runBackendBuild == true
assert forcedPlan.runMobileBuild == true
println('[OK] Caso 6: FORCE_FULL_BUILD incluye los 8 microservicios y mobile.')

// -----------------------------------------------------------------------------
// Caso 7: validación estricta de TARGET_ENV (CA2)
// -----------------------------------------------------------------------------
boolean invalidEnvRejected = false
try {
    multibranchFlow.normalizeTargetEnv('production')
} catch (IllegalArgumentException expected) {
    invalidEnvRejected = expected.message.contains('TARGET_ENV invalido')
}
assert invalidEnvRejected : 'Un TARGET_ENV desconocido debe fallar rápido'
println('[OK] Caso 7: TARGET_ENV invalido rechazado explicitamente.')

// -----------------------------------------------------------------------------
// Caso 8: publicación de estados PENDING/SUCCESS/FAILURE en GitHub (CA3)
// -----------------------------------------------------------------------------
Map pendingPayload = publishBuildStatus.call([state: 'PENDING', flow: prContext, dryRun: true])
assert pendingPayload.state == 'PENDING'
assert pendingPayload.context == 'continuous-integration/jenkins/pr-head'
assert pendingPayload.account == 'CrubioII'
assert pendingPayload.repo == 'circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093'
assert pendingPayload.resolvedRepository == true
assert pendingPayload.published == false

Map successPayload = publishBuildStatus.call([state: 'success', flow: mainContext, dryRun: true, description: 'CI OK'])
assert successPayload.state == 'SUCCESS'
assert successPayload.context == 'continuous-integration/jenkins/main'

Map abortedPayload = publishBuildStatus.call([state: 'ABORTED', flow: prContext, dryRun: true])
assert abortedPayload.state == 'ERROR'

String longDescription = 'x' * 200
Map truncatedPayload = publishBuildStatus.call([state: 'FAILURE', flow: prContext, dryRun: true, description: longDescription])
assert truncatedPayload.description.length() == 140
assert truncatedPayload.description.endsWith('...')

Map publishedPayload = publishBuildStatus.call([state: 'FAILURE', flow: mainContext, description: 'Fallo de pruebas'])
assert publishedPayload.published == true
assert notifiedStatuses.size() == 1
Map notification = notifiedStatuses[0]
assert notification.account == 'CrubioII'
assert notification.repo == 'circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093'
assert notification.context == 'continuous-integration/jenkins/main'
assert notification.status == 'FAILURE'
assert notification.sha == mockEnv.GIT_COMMIT
assert notification.credentialsId == 'github-credentials'
println('[OK] Caso 8: estados PR/main publicados en GitHub con contexto, commit y credencial.')

// -----------------------------------------------------------------------------
// Caso 9: parsing de repositorios HTTPS/SSH para la API de GitHub (CA3)
// -----------------------------------------------------------------------------
Map httpsRepo = publishBuildStatus.parseGitHubRepository('https://github.com/CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093.git')
assert httpsRepo.fullName == 'CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093'
assert httpsRepo.resolved == true

Map sshRepo = publishBuildStatus.parseGitHubRepository('git@github.com:CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093.git')
assert sshRepo.fullName == 'CrubioII/circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093'

Map unknownRepo = publishBuildStatus.parseGitHubRepository('https://gitlab.com/otro/repo.git')
assert unknownRepo.resolved == false
println('[OK] Caso 9: remotos HTTPS/SSH resueltos y remotos no-GitHub ignorados.')

// -----------------------------------------------------------------------------
// Caso 10: el Jenkinsfile carga y usa la Shared Library (CA1)
// -----------------------------------------------------------------------------
String jenkinsfileText = jenkinsfile.getText('UTF-8')
[
    "@Library('circleguard-shared-lib')",
    'multibranchFlow.collectContext(',
    'multibranchFlow.planPipeline(',
    'multibranchFlow.requireDeploymentAllowed(',
    'detectChangedServices(forceAll:',
    'pipelineUtils.buildGradleCommandForServices(',
    "publishBuildStatus(state: 'PENDING'",
    "publishBuildStatus(state: 'SUCCESS'",
    "publishBuildStatus(state: 'FAILURE'",
    'plan?.runBackendBuild == true',
    'plan?.runMobileBuild == true',
    "stage('E2E Playwright')",
    "sh 'npx playwright test'",
    'e2e/reports/junit/*.xml',
    'publishHTML(',
    'plan?.deploymentAllowed == true',
    'checkout scm',
    'post {'
].each { String required ->
    assert jenkinsfileText.contains(required) : "El Jenkinsfile no contiene el fragmento requerido: ${required}"
}
assert jenkinsfileText.contains('TARGET_ENV')
assert !jenkinsfileText.contains('stage(\'Deploy to Prod\')') : 'La etapa de despliegue debe ser una compuerta, no un despliegue directo'
println('[OK] Caso 10: Jenkinsfile cargado con @Library y todas las etapas/funciones requeridas.')

// -----------------------------------------------------------------------------
// Caso 11: el Jenkinsfile es Groovy válido (sin la anotación de Jenkins)
// -----------------------------------------------------------------------------
String groovySource = jenkinsfileText.readLines()
    .findAll { String line -> !line.trim().startsWith('@Library') }
    .join('\n')
new GroovyShell(new Binding()).parse(groovySource)
println('[OK] Caso 11: sintaxis Groovy del Jenkinsfile valida.')

// -----------------------------------------------------------------------------
// Caso 12: JCasC declara la Shared Library, el job Multibranch y el descubrimiento
// de ramas + Pull Requests (CA2 + CA3)
// -----------------------------------------------------------------------------
String casc = cascFile.getText('UTF-8')
[
    'name: "circleguard-shared-lib"',
    'defaultVersion: "main"',
    'multibranchPipelineJob(\'circleguard-monorepo\')',
    'repoOwner(\'CrubioII\')',
    'repository(\'circle-guard-finalproject-A00401838-A00402548-A00395559-A00378093\')',
    'credentialsId: "github-token"',
    'credentialsId(\'github-credentials\')',
    'gitHubBranchDiscovery',
    'gitHubPullRequestDiscovery',
    'strategyId(1)',
    'workflowBranchProjectFactory',
    "scriptPath('Jenkinsfile')",
    'periodicFolderTrigger',
    'orphanedItemStrategy',
    'githubpluginconfig'
].each { String required ->
    assert casc.contains(required) : "jenkins/ci/jenkins.yaml no contiene: ${required}"
}
assert !casc.contains('ghp_') : 'La configuración JCasC no debe contener tokens en texto plano'
println('[OK] Caso 12: JCasC registra la Shared Library y el job Multibranch con ramas + PRs.')

// -----------------------------------------------------------------------------
// Caso 13: YAML sintácticamente válido (si python3 + PyYAML están disponibles)
// -----------------------------------------------------------------------------
try {
    Process yamlCheck = new ProcessBuilder(
        'python3', '-c',
        // Comillas simples dentro del código Python: en Windows ProcessBuilder elimina las comillas dobles.
        "import yaml; data = yaml.safe_load(open('jenkins/ci/jenkins.yaml', encoding='utf-8')); " +
        "assert data['unclassified']['globalLibraries']['libraries'][0]['name'] == 'circleguard-shared-lib'; " +
        "assert 'multibranchPipelineJob' in data['jobs'][0]['script']; print('YAML_OK')"
    ).directory(repoRoot).redirectErrorStream(true).start()
    String yamlOutput = yamlCheck.inputStream.getText('UTF-8')
    int yamlExit = yamlCheck.waitFor()
    if (yamlOutput.contains("ModuleNotFoundError") || yamlOutput.contains("No module named 'yaml'")) {
        println('[SKIP] Caso 13: PyYAML no disponible en el entorno; se omite el parseo estricto del YAML.')
    } else {
        assert yamlExit == 0 : "YAML invalido o estructura inesperada:\n${yamlOutput}"
        assert yamlOutput.contains('YAML_OK')
        println('[OK] Caso 13: jenkins.yaml es YAML valido y conserva la estructura esperada.')
    }
} catch (AssertionError assertionError) {
    throw assertionError
} catch (Exception ignored) {
    println('[SKIP] Caso 13: python3/PyYAML no disponibles; se omite el parseo estricto del YAML.')
}

// -----------------------------------------------------------------------------
// Caso 14: script de webhook idempotente y con secreto enmascarado (CA3)
// -----------------------------------------------------------------------------
Process webhookTest = new ProcessBuilder(bashExecutable, 'jenkins/test/validateWebhookScript.sh')
    .directory(repoRoot)
    .redirectErrorStream(true)
    .start()
String webhookOutput = webhookTest.inputStream.getText('UTF-8')
int webhookExit = webhookTest.waitFor()
println(webhookOutput.readLines().collect { "  ${it}" }.join('\n'))
assert webhookExit == 0 : 'La validacion del webhook de GitHub fallo'
assert webhookOutput.contains('VALIDACION DEL WEBHOOK DE GITHUB COMPLETADA')
println('[OK] Caso 14: webhook idempotente con gh/curl (POST -> PATCH) y secreto enmascarado.')

// =============================================================================
// US-13 — Despliegue automático a dev y promoción a stage tras E2E
// =============================================================================
List<String> cdStages = ['Deploy to dev', 'Verify dev health', 'E2E against dev', 'Promote to stage', 'Verify stage health']

// -----------------------------------------------------------------------------
// Caso 15: solo main con build pesado despliega a dev y planifica la promoción (CA1)
// -----------------------------------------------------------------------------
Map mainCdPlan = multibranchFlow.planPipeline(mainContext, prDetection, [targetEnv: 'none'])
assert mainCdPlan.autoDeployDev == true : 'main con build pesado debe desplegar automáticamente a dev'
assert mainCdPlan.promoteToStage == true
assert mainCdPlan.stages.containsAll(cdStages)
int tagIndex = mainCdPlan.stages.indexOf('Generate Release Notes & Tag')
assert cdStages.collect { mainCdPlan.stages.indexOf(it) } == (1..cdStages.size()).collect { tagIndex + it } :
    'Las etapas de entrega continua deben ir, en orden, después de publicar y etiquetar la versión'

[prContext, featureContext].each { Map ctx ->
    Map p = multibranchFlow.planPipeline(ctx, prDetection, [targetEnv: 'dev'])
    assert p.autoDeployDev == false : "${ctx.branchName} no debe desplegar automáticamente"
    assert p.promoteToStage == false
    assert !p.stages.any { cdStages.contains(it) } : "${ctx.branchName} no debe planificar etapas de despliegue"
}
Map mainDocsPlan = multibranchFlow.planPipeline(mainContext, docsDetection, [targetEnv: 'none'])
assert mainDocsPlan.autoDeployDev == false : 'Un cambio solo de documentación en main no publica imágenes ni despliega'
println('[OK] Caso 15: main despliega a dev automáticamente; PR, feature y docs-only no despliegan.')

// -----------------------------------------------------------------------------
// Caso 16: la promoción a stage exige deploy + healthchecks + E2E exitosos (CA2 + CA3)
// -----------------------------------------------------------------------------
Map promoted = multibranchFlow.promotionDecision([deployDev: 'SUCCESS', verifyDev: 'SUCCESS', e2eDev: 'SUCCESS'], [version: '1.4.0'])
assert promoted.promote == true && promoted.status == 'PROMOTED' && promoted.blockedBy == []
assert promoted.targetEnv == 'stage' && promoted.version == '1.4.0'
assert promoted.reason.contains('1.4.0')

Map e2eBlocked = multibranchFlow.promotionDecision([deployDev: 'SUCCESS', verifyDev: 'SUCCESS', e2eDev: 'FAILURE'], [version: '1.4.0'])
assert e2eBlocked.promote == false && e2eBlocked.status == 'BLOCKED'
assert e2eBlocked.blockedBy == ['e2eDev'] && e2eBlocked.reason.contains('E2E')

Map healthBlocked = multibranchFlow.promotionDecision([deployDev: 'SUCCESS', verifyDev: 'FAILURE', e2eDev: 'NOT_RUN'])
assert healthBlocked.promote == false
assert healthBlocked.blockedBy == ['verifyDev', 'e2eDev'] && healthBlocked.reason.contains('healthchecks')

Map deployBlocked = multibranchFlow.promotionDecision([deployDev: 'FAILURE'])
assert deployBlocked.promote == false && deployBlocked.blockedBy[0] == 'deployDev'
assert deployBlocked.gates == [deployDev: 'FAILURE', verifyDev: 'NOT_RUN', e2eDev: 'NOT_RUN']

assert multibranchFlow.promotionDecision([:]).promote == false : 'Sin resultados nunca se promueve'
assert multibranchFlow.promotionDecision(null).promote == false
assert multibranchFlow.promotionDecision([deployDev: 'success', verifyDev: 'Success', e2eDev: 'SUCCESS']).promote == true
assert multibranchFlow.promotionDecision([deployDev: 'SUCCESS', verifyDev: 'SUCCESS', e2eDev: 'SKIPPED']).promote == false :
    'E2E omitidos no habilitan la promoción'
println('[OK] Caso 16: promoción a stage solo con deploy + healthchecks + E2E en SUCCESS; bloqueos explicados.')

// -----------------------------------------------------------------------------
// Caso 17: el Jenkinsfile cablea despliegue, verificación, E2E, promoción y registro (CA1-CA3)
// -----------------------------------------------------------------------------
[
    "stage('Deploy to dev')", "stage('Verify dev health')", "stage('E2E against dev')",
    "stage('Promote to stage')", "stage('Verify stage health')",
    'plan?.autoDeployDev == true', 'plan?.promoteToStage == true',
    './deploy/scripts/environment.sh deploy --env dev',
    './deploy/scripts/environment.sh verify --env dev',
    './deploy/scripts/run-e2e.sh --env dev',
    './deploy/scripts/environment.sh deploy --env stage',
    './deploy/scripts/environment.sh verify --env stage',
    'multibranchFlow.promotionDecision(deployResults',
    'reports/ci/promotion-stage.json', 'reports/ci/health-dev.json', 'e2e/reports/dev/junit/*.xml', "reportName           : 'Playwright E2E (dev)'",
    'requireReleaseVersion(versionMap)',
    "ENV_SSH_CREDENTIALS_ID = 'circleguard-env-ssh'", "NEXUS_CREDENTIALS_ID = 'nexus-credentials'",
    'sshUserPrivateKey(', 'currentBuild.description'
].each { String required ->
    assert jenkinsfileText.contains(required) : "El Jenkinsfile no contiene el fragmento de US-13: ${required}"
}
List<Integer> order = ["stage('Publish Images to Nexus')", "stage('Deploy to dev')", "stage('Verify dev health')",
                       "stage('E2E against dev')", "stage('Promote to stage')", "stage('Verify stage health')"]
    .collect { jenkinsfileText.indexOf(it) }
assert order == order.sort(false) : 'Orden requerido: publicar -> dev -> health -> E2E -> stage -> health stage'
assert !jenkinsfileText.contains('--env prod') : 'US-13 no despliega a prod (la aprobación de producción es US-31)'
assert !(jenkinsfileText =~ /versionMap\.APP_VERSION \?: '0\.1\.0'\)\s*\n\s*echo "Desplegando/) :
    'El despliegue no debe usar una versión por defecto'
println('[OK] Caso 17: Jenkinsfile despliega dev -> E2E -> stage en orden, con credenciales y registro de la decisión.')

// -----------------------------------------------------------------------------
// Caso 18: scripts de despliegue (validaciones, SSH/SCP, secretos, puertos) (CA1 + CA3)
// -----------------------------------------------------------------------------
Process deployTests = new ProcessBuilder(bashExecutable, 'deploy/scripts/test-deploy-scripts.sh')
    .directory(repoRoot).redirectErrorStream(true).start()
String deployTestsOutput = deployTests.inputStream.getText('UTF-8')
int deployTestsExit = deployTests.waitFor()
println(deployTestsOutput.readLines().findAll { it.contains('[FAIL]') || it.contains('RESULTADO') }.collect { "  ${it}" }.join('\n'))
assert deployTestsExit == 0 : "deploy/scripts/test-deploy-scripts.sh falló:\n${deployTestsOutput}"
println('[OK] Caso 18: deploy/scripts validados (SemVer, ambientes, SSH/SCP, contraseña fuera de argumentos, puertos).')

// -----------------------------------------------------------------------------
// Caso 19: la compuerta E2E contra dev ejecuta los flujos de US-17 en modo real + contratos @deployed (CA2)
// -----------------------------------------------------------------------------
File e2eDir = new File(repoRoot, 'e2e')
String e2ePackage = new File(e2eDir, 'package.json').getText('UTF-8')
assert e2ePackage.contains('"test:deployed"') && e2ePackage.contains('"@playwright/test"')
assert new File(e2eDir, 'package-lock.json').exists() : 'npm ci requiere e2e/package-lock.json'
String e2eConfig = new File(e2eDir, 'playwright.config.ts').getText('UTF-8')
assert e2eConfig.contains("name: 'deployed-api'") && e2eConfig.contains('E2E_TARGET_ENV') && e2eConfig.contains('E2E_REPORT_DIR')
assert e2eConfig.contains("testIgnore: '**/deployed/**'") : 'La etapa E2E previa al despliegue (US-34) no debe ejecutar los contratos @deployed'
List<String> deployedSpecs = new File(e2eDir, 'tests/deployed').listFiles().findAll { it.name.endsWith('.spec.ts') }*.name.sort()
assert deployedSpecs.containsAll(['auth-identity.spec.ts', 'gate-qr.spec.ts', 'health.spec.ts', 'web-client.spec.ts']) : "Specs @deployed: ${deployedSpecs}"
List<String> us17Flows = new File(e2eDir, 'tests/flows').listFiles().findAll { it.name.endsWith('.spec.ts') }*.name.sort()
assert us17Flows.containsAll(['access-validation.spec.ts', 'health-questionnaire.spec.ts', 'login.spec.ts']) : "Flujos US-17: ${us17Flows}"
String runE2e = new File(repoRoot, 'deploy/scripts/run-e2e.sh').getText('UTF-8')
['export E2E_MOCK_API=false', 'export E2E_RUNTIME_CONFIG_FROM_ENV=1', '--project=chromium --project=deployed-api',
 'npx playwright install chromium', 'E2E_REPORT_DIR="reports/${ENV_NAME}"'].each { String required ->
    assert runE2e.contains(required) : "deploy/scripts/run-e2e.sh no contiene: ${required}"
}
assert new File(e2eDir, 'support/fixtures.ts').getText('UTF-8').contains('E2E_RUNTIME_CONFIG_FROM_ENV')
println("[OK] Caso 19: dev se valida con ${us17Flows.size()} flujos US-17 reales + ${deployedSpecs.size()} contratos @deployed.")

// =============================================================================
// US-31 — Aprobación manual y despliegue verificado a prod
// =============================================================================
List<String> prodStages = ['Approve prod release', 'Deploy to prod', 'Verify prod health']

// -----------------------------------------------------------------------------
// Caso 20: el release a prod solo se planifica en main, después de stage (CA1)
// -----------------------------------------------------------------------------
Map mainProdReleasePlan = multibranchFlow.planPipeline(mainContext, prDetection, [targetEnv: 'none'])
assert mainProdReleasePlan.prodRelease == true
int verifyStageIndex = mainProdReleasePlan.stages.indexOf('Verify stage health')
assert prodStages.collect { mainProdReleasePlan.stages.indexOf(it) } == (1..prodStages.size()).collect { verifyStageIndex + it } :
    'Aprobar -> desplegar -> verificar prod deben ir, en orden, justo después de verificar stage'
[prContext, featureContext].each { Map ctx ->
    Map p = multibranchFlow.planPipeline(ctx, prDetection, [targetEnv: 'prod'])
    assert p.prodRelease == false && !p.stages.any { prodStages.contains(it) } : "${ctx.branchName} nunca llega a prod"
}
assert multibranchFlow.planPipeline(mainContext, docsDetection, [targetEnv: 'none']).prodRelease == false
assert multibranchFlow.parseProdApprovers(' ana, luis  release-managers ,ana') == ['ana', 'luis', 'release-managers']
assert multibranchFlow.parseProdApprovers('') == [] && multibranchFlow.parseProdApprovers(null) == []
println('[OK] Caso 20: release a prod solo en main tras stage; aprobadores configurables (CG_PROD_APPROVERS).')

// -----------------------------------------------------------------------------
// Caso 21: decisión de la compuerta manual: quién, qué versión y si se despliega (CA1 + CA2)
// -----------------------------------------------------------------------------
Map approvalCfg = [outcome: 'SUBMITTED', validatedVersion: '1.4.0', approvers: ['ana', 'luis']]
Map prodApproved = multibranchFlow.prodApprovalDecision(
    [DECISION: 'APROBAR', VERSION: '1.4.0', COMMENT: 'RFC-012 ventana nocturna', APPROVER: 'ana'], approvalCfg)
assert prodApproved.status == 'APPROVED' && prodApproved.deploy == true
assert prodApproved.approver == 'ana' && prodApproved.version == '1.4.0' && prodApproved.comment == 'RFC-012 ventana nocturna'
assert prodApproved.reason.contains('ana') && prodApproved.reason.contains('1.4.0')

Map prodRejected = multibranchFlow.prodApprovalDecision(
    [DECISION: 'RECHAZAR', VERSION: '1.4.0', COMMENT: 'Falta validar con negocio', APPROVER: 'luis'], approvalCfg)
assert prodRejected.status == 'REJECTED' && prodRejected.deploy == false
assert prodRejected.approver == 'luis' && prodRejected.reason.contains('luis') && prodRejected.reason.contains('Falta validar')

assert multibranchFlow.prodApprovalDecision(
    [DECISION: 'APROBAR', VERSION: '1.3.9', COMMENT: 'RFC-013', APPROVER: 'ana'], approvalCfg).status == 'INVALID' :
    'Solo se puede aprobar la versión validada en stage'
assert multibranchFlow.prodApprovalDecision(
    [DECISION: 'APROBAR', VERSION: '1.4.0', COMMENT: '', APPROVER: 'ana'], approvalCfg).status == 'INVALID' :
    'La aprobación exige comentario o RFC'
assert multibranchFlow.prodApprovalDecision(
    [DECISION: 'APROBAR', VERSION: '1.4.0', COMMENT: 'RFC-014', APPROVER: ''], approvalCfg).status == 'INVALID' :
    'Sin aprobador identificado no se despliega'
assert multibranchFlow.prodApprovalDecision(
    [DECISION: 'TALVEZ', VERSION: '1.4.0', COMMENT: 'RFC-015', APPROVER: 'ana'], approvalCfg).deploy == false
// Jenkins deja a los administradores responder cualquier input: solo cuentan los de CG_PROD_APPROVERS.
Map intruder = multibranchFlow.prodApprovalDecision(
    [DECISION: 'APROBAR', VERSION: '1.4.0', COMMENT: 'RFC-016', APPROVER: 'eve'], approvalCfg)
assert intruder.status == 'INVALID' && !intruder.deploy && intruder.reason.contains('eve')
assert multibranchFlow.prodApprovalDecision(
    [DECISION: 'RECHAZAR', VERSION: '1.4.0', COMMENT: 'no', APPROVER: 'eve'], approvalCfg).status == 'INVALID' :
    'Un no autorizado tampoco puede rechazar'
assert multibranchFlow.prodApprovalDecision(
    [DECISION: 'APROBAR', VERSION: '1.4.0', COMMENT: 'RFC-017', APPROVER: 'ANA'], approvalCfg).status == 'APPROVED' :
    'Los IDs de usuario de Jenkins no distinguen mayúsculas'

Map timedOut = multibranchFlow.prodApprovalDecision([:], approvalCfg + [outcome: 'TIMEOUT'])
assert timedOut.status == 'TIMEOUT' && !timedOut.deploy
Map prodAborted = multibranchFlow.prodApprovalDecision([:], approvalCfg + [outcome: 'ABORTED', abortedBy: 'luis'])
assert prodAborted.status == 'ABORTED' && !prodAborted.deploy && prodAborted.reason.contains('luis')
Map notConfigured = multibranchFlow.prodApprovalDecision([:], approvalCfg + [approvers: []])
assert notConfigured.status == 'NOT_CONFIGURED' && !notConfigured.deploy && notConfigured.reason.contains('CG_PROD_APPROVERS')
assert multibranchFlow.prodApprovalDecision(
    [DECISION: 'APROBAR', VERSION: '', COMMENT: 'RFC', APPROVER: 'ana'], approvalCfg + [validatedVersion: '']).status == 'INVALID'
println('[OK] Caso 21: aprobar/rechazar registran quién y qué versión; timeout, abort, versión no validada y falta de aprobadores no despliegan.')

println('=== TODAS LAS PRUEBAS DEL MULTIBRANCH PIPELINE PASARON EXITOSAMENTE ===')
