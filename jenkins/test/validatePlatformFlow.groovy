// jenkins/test/validatePlatformFlow.groovy
// Historia de Usuario: US-22 (Terraform en Jenkins).
// Propósito: validar sin Jenkins el plan de etapas de plataforma, la compuerta de apply
// por ambiente, el cableado del Jenkinsfile y los scripts de plataforma.

import groovy.lang.Binding
import groovy.lang.GroovyShell

File repoRoot = new File(System.getProperty('circleguard.repoRoot') ?: '.').canonicalFile
File platformScript = new File(repoRoot, 'jenkins/vars/platformFlow.groovy')
File jenkinsfile = new File(repoRoot, 'Jenkinsfile')
File dockerfile = new File(repoRoot, 'infra/bootstrap/jenkins/Dockerfile')
[platformScript, jenkinsfile, dockerfile].each { assert it.exists() : "Falta ${it.path}" }

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

println('=== Validación de plataforma: Terraform en Jenkins (US-22) ===')

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
    "AWS_TERRAFORM_CREDENTIALS_ID = 'aws-terraform'", "name: 'FORCE_TERRAFORM'"
].each { String required ->
    assert jf.contains(required) : "El Jenkinsfile no contiene: ${required}"
}
List<Integer> order = [
    "stage('Terraform Plan')", "stage('Publish Images to Nexus')", "stage('Terraform Apply dev')", "stage('Deploy to dev')",
    "stage('E2E against dev')", "stage('Terraform Apply stage')", "stage('Promote to stage')",
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
['ARG TERRAFORM_VERSION=', 'sha256sum'].each {
    assert df.contains(it) : "El Dockerfile de Jenkins no contiene: ${it}"
}
println('[OK] Caso 9: imagen de Jenkins con terraform verificados por SHA-256.')

// -----------------------------------------------------------------------------
// Caso 10: scripts de plataforma (binarios simulados, sin AWS ni clúster).
// -----------------------------------------------------------------------------
[['infra/scripts/test-platform-scripts.sh', 'RESULTADO: OK']].each { List t ->
    Process p = new ProcessBuilder(bashExecutable, t[0]).directory(repoRoot).redirectErrorStream(true).start()
    String output = p.inputStream.getText('UTF-8')
    int code = p.waitFor()
    assert code == 0 && output.contains(t[1]) : "${t[0]} falló:\n${output}"
}
println('[OK] Caso 10: tf-pipeline.sh validado.')

println('=== TODAS LAS PRUEBAS DE PLATAFORMA (US-22) PASARON EXITOSAMENTE ===')
