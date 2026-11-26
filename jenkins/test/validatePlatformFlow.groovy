// jenkins/test/validatePlatformFlow.groovy
// Historias de Usuario: US-22 (Terraform en Jenkins), US-38 (Trivy bloqueante),
// US-39 (despliegue y promoción en Kubernetes) y US-28 (rollback en Kubernetes).
// Propósito: validar sin Jenkins el plan de etapas de plataforma, la compuerta de apply
// por ambiente, el cableado del Jenkinsfile y los scripts de plataforma.

import groovy.lang.Binding
import groovy.lang.GroovyShell

File repoRoot = new File(System.getProperty('circleguard.repoRoot') ?: '.').canonicalFile
File platformScript = new File(repoRoot, 'jenkins/vars/platformFlow.groovy')
File rollbackScript = new File(repoRoot, 'jenkins/vars/rollbackDeployment.groovy')
File jenkinsfile = new File(repoRoot, 'Jenkinsfile')
File dockerfile = new File(repoRoot, 'infra/bootstrap/jenkins/Dockerfile')
[platformScript, rollbackScript, jenkinsfile, dockerfile].each { assert it.exists() : "Falta ${it.path}" }

boolean isWindowsHost = System.getProperty('os.name').toLowerCase().contains('windows')
String bashExecutable = System.getenv('BASH_EXE') ?:
    (['C:/Program Files/Git/bin/bash.exe', 'C:/Program Files (x86)/Git/bin/bash.exe']
        .find { String candidate -> isWindowsHost && new File(candidate).exists() } ?: 'bash')

List<String> shCalls = []
Binding binding = new Binding()
binding.setVariable('echo', { String m -> println("[JENKINS-ECHO] ${m}") })
binding.setVariable('error', { String m -> throw new IllegalStateException(m) })
binding.setVariable('sh', { String cmd -> shCalls << cmd })
binding.setVariable('withEnv', { List vars, Closure body -> body() })
GroovyShell shell = new GroovyShell(binding)
def platformFlow = shell.parse(platformScript)
def rollbackDeployment = shell.parse(rollbackScript)

println('=== Validación de plataforma: Terraform, Trivy, Kubernetes y rollback (US-22/38/39/28) ===')

Map mainPlan = [runHeavyBuild: true, isMainBranch: true, autoDeployDev: true]
Map prPlan = [runHeavyBuild: true, isMainBranch: false, autoDeployDev: false]
Map docsPlan = [runHeavyBuild: false, isMainBranch: true, autoDeployDev: false]
Map tfDetection = [changedFiles: ['infra/terraform/modules/storage/main.tf', 'README.md']]
Map appDetection = [changedFiles: ['services/circleguard-auth-service/src/main/java/A.java']]
Map tfDocsDetection = [changedFiles: ['infra/terraform/README.md', 'infra/terraform/modules/storage/README.md']]

// -----------------------------------------------------------------------------
// Caso 1 (US-22 CA1): un PR que toca infra/terraform hace plan y nunca apply.
// -----------------------------------------------------------------------------
Map prTf = platformFlow.planPlatform(prPlan, tfDetection)
assert prTf.terraformChanged && prTf.runTerraformPlan && !prTf.terraformApply
assert prTf.terraformFiles == ['infra/terraform/modules/storage/main.tf']
assert prTf.stages.contains('Terraform Plan') && !prTf.stages.any { it.startsWith('Terraform Apply') }
println('[OK] Caso 1: PR con cambios de Terraform corre plan de los 3 ambientes y no aplica.')

// -----------------------------------------------------------------------------
// Caso 2 (US-22 CA2): main con cambios de Terraform planifica apply en dev, stage y prod.
// -----------------------------------------------------------------------------
Map mainTf = platformFlow.planPlatform(mainPlan, tfDetection)
assert mainTf.runTerraformPlan && mainTf.terraformApply
assert mainTf.stages.findAll { it.startsWith('Terraform Apply') } == ['Terraform Apply dev', 'Terraform Apply stage', 'Terraform Apply prod']
println('[OK] Caso 2: main aplica Terraform en dev, stage y prod (en ese orden).')

// -----------------------------------------------------------------------------
// Caso 3: sin cambios de Terraform no hay plan; README de infra/terraform no dispara plan;
// FORCE_TERRAFORM lo fuerza.
// -----------------------------------------------------------------------------
assert !platformFlow.planPlatform(mainPlan, appDetection).runTerraformPlan
assert !platformFlow.planPlatform(prPlan, tfDocsDetection).runTerraformPlan
Map forced = platformFlow.planPlatform(prPlan, appDetection, [forceTerraform: true])
assert forced.runTerraformPlan && !forced.terraformApply
assert platformFlow.planPlatform(mainPlan, appDetection, [forceTerraform: true]).terraformApply
println('[OK] Caso 3: plan solo con cambios reales de .tf/.tfvars/.hcl o con FORCE_TERRAFORM.')

// -----------------------------------------------------------------------------
// Caso 3b: sin la credencial de AWS no hay plan ni apply (salvo FORCE_TERRAFORM, que falla);
// sin CG_TERRAFORM_APPLY=true main solo planifica.
// -----------------------------------------------------------------------------
Map noCreds = platformFlow.planPlatform(prPlan, tfDetection, [terraformCredentials: false])
assert noCreds.terraformChanged && !noCreds.runTerraformPlan && !noCreds.terraformApply
assert !noCreds.stages.contains('Terraform Plan') && noCreds.terraformNote.contains('Sin credencial')
assert !platformFlow.planPlatform(mainPlan, tfDetection, [terraformCredentials: false]).terraformApply
assert platformFlow.planPlatform(mainPlan, appDetection, [terraformCredentials: false]).terraformNote == ''
try {
    platformFlow.planPlatform(prPlan, appDetection, [forceTerraform: true, terraformCredentials: false])
    assert false : 'FORCE_TERRAFORM sin credencial debería fallar'
} catch (IllegalStateException expected) {
    assert expected.message.contains('FORCE_TERRAFORM')
}
Map planOnly = platformFlow.planPlatform(mainPlan, tfDetection, [terraformApplyEnabled: false])
assert planOnly.runTerraformPlan && !planOnly.terraformApply && planOnly.terraformNote.contains('CG_TERRAFORM_APPLY')
assert planOnly.stages.contains('Terraform Plan') && !planOnly.stages.any { it.startsWith('Terraform Apply') }
assert !platformFlow.terraformApplyDecision(planOnly, 'dev').apply
assert platformFlow.planPlatform(prPlan, tfDetection, [terraformApplyEnabled: false]).terraformNote == ''
println('[OK] Caso 3b: sin credencial se omite Terraform y sin CG_TERRAFORM_APPLY main solo hace plan.')

// -----------------------------------------------------------------------------
// Caso 4 (US-22 CA2): compuerta de apply por ambiente.
// -----------------------------------------------------------------------------
assert platformFlow.terraformApplyDecision(mainTf, 'dev').apply
Map okGates = [deployDev: 'SUCCESS', verifyDev: 'SUCCESS', e2eDev: 'SUCCESS']
assert platformFlow.terraformApplyDecision(mainTf, 'stage', [deployResults: okGates]).apply
assert !platformFlow.terraformApplyDecision(mainTf, 'stage', [deployResults: okGates + [e2eDev: 'FAILURE']]).apply
assert !platformFlow.terraformApplyDecision(mainTf, 'prod', [prodApproval: [deploy: false]]).apply
Map prodOk = platformFlow.terraformApplyDecision(mainTf, 'prod', [prodApproval: [deploy: true, approver: 'ana']])
assert prodOk.apply && prodOk.reason.contains('ana')
assert !platformFlow.terraformApplyDecision(prTf, 'dev').apply : 'Un PR nunca aplica'
try {
    platformFlow.terraformApplyDecision(mainTf, 'qa')
    assert false : 'Ambiente inválido debería fallar'
} catch (IllegalArgumentException expected) { }
println('[OK] Caso 4: dev aplica directo, stage tras dev+E2E y prod solo con la aprobación de US-31.')

// -----------------------------------------------------------------------------
// Caso 5 (US-38 CA1/CA2): Trivy config en todo build pesado; trivy image solo en main.
// -----------------------------------------------------------------------------
assert prTf.runTrivyConfig && !prTf.runTrivyImages
assert mainTf.runTrivyConfig && mainTf.runTrivyImages && mainTf.trivySeverity == 'HIGH,CRITICAL'
assert mainTf.releaseImages.size() == 9 && mainTf.releaseImages.contains('mobile')
assert mainTf.stages.indexOf('Build Images') < mainTf.stages.indexOf('Trivy Image Scan')
assert mainTf.stages.indexOf('Trivy Image Scan') < mainTf.stages.indexOf('Publish Images to Nexus')
Map noTrivy = platformFlow.planPlatform(mainPlan, appDetection, [enableTrivy: false])
assert !noTrivy.runTrivyConfig && !noTrivy.runTrivyImages && !noTrivy.stages.contains('Trivy Image Scan')
assert !platformFlow.planPlatform(docsPlan, [changedFiles: ['docs/a.md']]).runTrivyConfig
println('[OK] Caso 5: Trivy IaC en PR y main, imágenes escaneadas entre build y publicación, HIGH/CRITICAL.')

// -----------------------------------------------------------------------------
// Caso 6 (US-39): plataforma de despliegue.
// -----------------------------------------------------------------------------
assert platformFlow.resolveDeployPlatform('default', '', false).platform == 'compose'
assert platformFlow.resolveDeployPlatform('default', 'k8s', true) == [platform: 'k8s', source: 'CG_DEPLOY_PLATFORM']
assert platformFlow.resolveDeployPlatform('compose', 'k8s', true).platform == 'compose'
assert platformFlow.resolveDeployPlatform('k8s', '', true).source == 'parámetro DEPLOY_PLATFORM'
[['k8s', '', false], ['swarm', '', true], ['default', 'nomad', true]].each { List args ->
    try {
        platformFlow.resolveDeployPlatform(*args)
        assert false : "Debería rechazar ${args}"
    } catch (IllegalStateException | IllegalArgumentException expected) { }
}
assert platformFlow.planPlatform(mainPlan, appDetection, [deployPlatform: 'k8s', k8sOverlaysPresent: true]).deployPlatform == 'k8s'
println('[OK] Caso 6: compose por defecto, k8s por parámetro o CG_DEPLOY_PLATFORM y solo con overlays de US-21.')

// -----------------------------------------------------------------------------
// Caso 7 (US-28): rollbackDeployment admite la plataforma k8s.
// -----------------------------------------------------------------------------
shCalls.clear()
Map rb = rollbackDeployment.call(env: 'stage', platform: 'k8s', host: '10.0.0.5')
assert rb.platform == 'k8s' && rb.targetVersion == 'previous_revision'
assert shCalls[0].contains("rollback 'stage' --platform k8s") && !shCalls[0].contains('--host')
shCalls.clear()
rollbackDeployment.call(env: 'prod', platform: 'k8s', targetVersion: '1.3.0')
assert shCalls[0].contains("rollback 'prod' --to '1.3.0' --platform k8s")
shCalls.clear()
rollbackDeployment.call(env: 'dev', host: '10.0.0.9')
assert shCalls[0].contains("--host '10.0.0.9'") && !shCalls[0].contains('--platform')
try {
    rollbackDeployment.call(env: 'dev', platform: 'swarm')
    assert false
} catch (IllegalStateException expected) { }
println('[OK] Caso 7: rollbackDeployment hace rollout undo o redeploy de etiqueta en k8s sin romper el modo compose.')

// -----------------------------------------------------------------------------
// Caso 7b (US-28): rollback manual solo desde main, versión SemVer y flujo apagado.
// -----------------------------------------------------------------------------
Map mainCtx = [isMainBranch: true, isPullRequest: false, branchName: 'main']
Map prCtx = [isMainBranch: false, isPullRequest: true, branchName: 'PR-9']
assert !platformFlow.rollbackRequest(mainCtx, 'none', '').requested
Map rbStage = platformFlow.rollbackRequest(mainCtx, 'stage', '1.3.0')
assert rbStage.allowed && rbStage.version == '1.3.0' && !rbStage.requiresApproval
assert platformFlow.rollbackRequest(mainCtx, 'prod', '').requiresApproval
assert !platformFlow.rollbackRequest(prCtx, 'dev', '').allowed : 'Un PR no puede hacer rollback'
[['qa', ''], ['dev', 'latest'], ['dev', '1.3']].each { List a ->
    try {
        platformFlow.rollbackRequest(mainCtx, a[0], a[1])
        assert false : "Debería rechazar ${a}"
    } catch (IllegalArgumentException expected) { }
}
Map rbPlans = platformFlow.rollbackOnlyPlans(mainPlan + [prodRelease: true, promoteToStage: true], mainTf)
assert rbPlans.plan.rollbackOnly && !rbPlans.plan.runHeavyBuild && !rbPlans.plan.autoDeployDev && !rbPlans.plan.prodRelease
assert !rbPlans.platform.terraformApply && !rbPlans.platform.runTrivyImages && rbPlans.platform.stages == ['Manual Rollback']
assert mainTf.terraformApply : 'rollbackOnlyPlans no modifica el plan original'
println('[OK] Caso 7b: rollback manual solo en main, SemVer, prod con aprobación y sin build ni despliegue nuevo.')

// -----------------------------------------------------------------------------
// Caso 8: el Jenkinsfile cablea las etapas de plataforma en el orden correcto.
// -----------------------------------------------------------------------------
String jf = jenkinsfile.getText('UTF-8')
[
    // US-22
    "platformFlow = load 'jenkins/vars/platformFlow.groovy'",
    'platformFlow.planPlatform(plan, detection',
    "stage('Terraform Plan')", 'platform?.runTerraformPlan == true',
    "./infra/terraform/scripts/tf-pipeline.sh plan --env '\${tfEnv}'",
    "archiveArtifacts artifacts: 'reports/terraform/*-plan.txt",
    "stage('Terraform Apply dev')", "stage('Terraform Apply stage')", "stage('Terraform Apply prod')",
    "platformFlow.terraformApplyDecision(platform, 'stage', [deployResults: deployResults])",
    "platformFlow.terraformApplyDecision(platform, 'prod', [prodApproval: prodApproval])",
    "AWS_TERRAFORM_CREDENTIALS_ID = 'aws-terraform'", "name: 'FORCE_TERRAFORM'",
    'terraformCredentials : terraformCredentialsPresent()',
    "TERRAFORM_APPLY_ENABLED = \"\${env.CG_TERRAFORM_APPLY ?: 'false'}\"",
    "terraformApplyEnabled: env.TERRAFORM_APPLY_ENABLED == 'true'",
    "\"TF_STATE_BUCKET=\${env.TF_STATE_BUCKET ?: ''}\"",
    // US-38
    "stage('Trivy IaC Scan')", './infra/scripts/trivy-scan.sh config --target infra/terraform --target deploy/k8s',
    "stage('Build Images')", "stage('Trivy Image Scan')", './infra/scripts/trivy-scan.sh image --version',
    'DO_PUSH=false', 'PUSH_ONLY=true', "testResults: 'reports/trivy/junit/image-*.xml'", "name: 'ENABLE_TRIVY_GATE'",
    // US-39
    "name: 'DEPLOY_PLATFORM'", "credentialsId: \"kubeconfig-\${envName}\"",
    "./deploy/scripts/k8s-deploy.sh deploy --env dev --version '\${version}'",
    "./deploy/scripts/k8s-deploy.sh deploy --env stage --version '\${version}'",
    "./deploy/scripts/k8s-deploy.sh deploy --env prod --version '\${prodApproval.version}'",
    './deploy/scripts/k8s-deploy.sh verify --env', "sh './deploy/scripts/run-e2e.sh --env dev --k8s'",
    "script: './infra/scripts/zap-scan.sh --env dev --k8s'",  // US-44
    // US-28
    "./infra/scripts/rollback.sh rollback '\${envName}' --platform k8s",
    "stage('Manual Rollback')", "name: 'ROLLBACK_ENV'", "name: 'ROLLBACK_TARGET_VERSION'",
    'platformFlow.rollbackRequest(flow, params.ROLLBACK_ENV, params.ROLLBACK_TARGET_VERSION)',
    'platformFlow.rollbackOnlyPlans(plan, platform)', "input(id: 'ProdRollback'",
    'flow?.isMainBranch == true && plan?.rollbackOnly != true'
].each { String required ->
    assert jf.contains(required) : "El Jenkinsfile no contiene: ${required}"
}
List<Integer> order = [
    "stage('Terraform Plan')", "stage('Trivy IaC Scan')", "stage('Build Images')", "stage('Trivy Image Scan')",
    "stage('Publish Images to Nexus')", "stage('Terraform Apply dev')", "stage('Deploy to dev')",
    "stage('E2E against dev')", "stage('ZAP Baseline against dev')", "stage('Terraform Apply stage')", "stage('Promote to stage')",
    "stage('Approve prod release')", "stage('Terraform Apply prod')", "stage('Deploy to prod')"
].collect { jf.indexOf(it) }
assert !order.contains(-1) && order == order.sort(false) : "Orden de etapas incorrecto: ${order}"
assert jf.indexOf("stage('Terraform Apply prod')") > jf.indexOf("stage('Approve prod release')") :
    'Terraform nunca toca prod antes de la aprobación manual'
println('[OK] Caso 8: Jenkinsfile con las etapas de plataforma cableadas y en orden.')

// -----------------------------------------------------------------------------
// Caso 9: la imagen de Jenkins trae las herramientas con versión fija y checksum.
// -----------------------------------------------------------------------------
String df = dockerfile.getText('UTF-8')
['ARG TERRAFORM_VERSION=', 'ARG TRIVY_VERSION=', 'ARG KUBECTL_VERSION=', 'sha256sum', '/usr/local/share/trivy/templates'].each {
    assert df.contains(it) : "El Dockerfile de Jenkins no contiene: ${it}"
}
println('[OK] Caso 9: imagen de Jenkins con terraform, trivy (plantillas) y kubectl verificados por SHA-256.')

// -----------------------------------------------------------------------------
// Caso 10: scripts de plataforma (binarios simulados, sin AWS ni clúster).
// -----------------------------------------------------------------------------
[['infra/scripts/test-platform-scripts.sh', 'RESULTADO: OK'], ['infra/scripts/test-rollback.sh', 'Todas las pruebas']].each { List t ->
    Process p = new ProcessBuilder(bashExecutable, t[0]).directory(repoRoot).redirectErrorStream(true).start()
    String output = p.inputStream.getText('UTF-8')
    int code = p.waitFor()
    assert code == 0 && output.contains(t[1]) : "${t[0]} falló:\n${output}"
}
println('[OK] Caso 10: tf-pipeline.sh, trivy-scan.sh, k8s-deploy.sh y rollback.sh validados.')

println('=== TODAS LAS PRUEBAS DE PLATAFORMA (US-22/38/39/28) PASARON EXITOSAMENTE ===')
