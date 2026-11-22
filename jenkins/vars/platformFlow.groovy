// jenkins/vars/platformFlow.groovy
// Historias de Usuario: US-22 (Terraform en Jenkins) y US-38 (Trivy bloqueante).
//
// Propósito: decidir, sin depender de una instancia Jenkins, qué etapas de plataforma
// corre cada build. El Jenkinsfile lo carga desde el workspace (load), igual que
// sonarQualityGate, para que cada rama valide su propia versión del paso.
//
//   - Terraform: `plan` de los tres ambientes en cada PR o build de main que toque
//     infra/terraform; `apply` automático en dev y stage, y en prod solo después de la
//     aprobación manual de US-31.
//   - Trivy: `trivy config` sobre infra/terraform y deploy/k8s en todo build pesado, y
//     `trivy image` sobre las 9 imágenes antes de publicarlas en Nexus (solo main).

import groovy.transform.Field

@Field final String TERRAFORM_ROOT = 'infra/terraform/'
@Field final List<String> TERRAFORM_ENVS = ['dev', 'stage', 'prod']
@Field final List<String> TERRAFORM_FILE_SUFFIXES = ['.tf', '.tfvars', '.hcl', '.tftest.hcl', '.sh']
// US-38 CA2: severidades que rompen el build.
@Field final String TRIVY_BLOCKING_SEVERITY = 'HIGH,CRITICAL'
// Las 9 imágenes que publica infra/scripts/publish-docker-images.sh (US-11).
@Field final List<String> RELEASE_IMAGES = [
    'auth', 'identity', 'promotion', 'notification', 'form', 'file', 'gateway', 'dashboard', 'mobile'
]
@Field final List<String> TERRAFORM_STAGES = ['Terraform Plan']
@Field final List<String> TRIVY_STAGES = ['Trivy IaC Scan']
@Field final List<String> IMAGE_RELEASE_STAGES = ['Build Images', 'Trivy Image Scan', 'Publish Images to Nexus']

Map call(Map plan, Map detection, Map config = [:]) {
    return planPlatform(plan, detection, config)
}

/**
 * Archivos de Terraform que cuentan como cambio de infraestructura. Los README y
 * diagramas de infra/terraform no disparan un plan.
 */
boolean isTerraformChange(String file) {
    String path = (file ?: '').replace('\\', '/').trim()
    return path.startsWith(TERRAFORM_ROOT) && TERRAFORM_FILE_SUFFIXES.any { path.endsWith(it) }
}

/**
 * Plan de etapas de plataforma a partir del plan de multibranchFlow y de la detección
 * de cambios. Es la única fuente de verdad para los `when` de estas etapas.
 *
 * config:
 *   - forceTerraform (boolean): corre plan/apply aunque no cambie infra/terraform.
 *   - enableTrivy (boolean): ENABLE_TRIVY_GATE (por defecto true).
 */
Map planPlatform(Map plan, Map detection, Map config = [:]) {
    List<String> changed = ((detection?.changedFiles ?: []) as List).collect { it.toString() }
    boolean forceTerraform = (config.forceTerraform ?: false) as boolean
    boolean enableTrivy = (config.containsKey('enableTrivy') ? config.enableTrivy : true) as boolean
    boolean heavy = (plan?.runHeavyBuild ?: false) as boolean
    boolean isMain = (plan?.isMainBranch ?: false) as boolean
    boolean autoDeploy = (plan?.autoDeployDev ?: false) as boolean

    List<String> terraformFiles = changed.findAll { isTerraformChange(it) }
    boolean terraformChanged = forceTerraform || !terraformFiles.isEmpty()

    // US-22 CA1: plan en cada PR (y en main) que modifique infra/terraform.
    boolean runTerraformPlan = terraformChanged && (heavy || forceTerraform)
    // US-22 CA2: apply solo desde main, en el mismo orden de promoción que la aplicación.
    boolean terraformApply = runTerraformPlan && autoDeploy
    // US-38 CA1: trivy config en todo build pesado (PR y main); trivy image antes de publicar.
    boolean runTrivyConfig = enableTrivy && heavy
    boolean runTrivyImages = enableTrivy && isMain && heavy

    List<String> stages = []
    if (runTerraformPlan) {
        stages.addAll(TERRAFORM_STAGES)
    }
    if (runTrivyConfig) {
        stages.addAll(TRIVY_STAGES)
    }
    if (isMain && heavy) {
        stages.addAll(runTrivyImages ? IMAGE_RELEASE_STAGES : IMAGE_RELEASE_STAGES.findAll { it != 'Trivy Image Scan' })
    }
    if (terraformApply) {
        stages.addAll(TERRAFORM_ENVS.collect { "Terraform Apply ${it}".toString() })
    }

    return [
        terraformChanged  : terraformChanged,
        terraformFiles    : terraformFiles,
        terraformEnvs     : TERRAFORM_ENVS,
        runTerraformPlan  : runTerraformPlan,
        terraformApply    : terraformApply,
        runTrivyConfig    : runTrivyConfig,
        runTrivyImages    : runTrivyImages,
        trivySeverity     : TRIVY_BLOCKING_SEVERITY,
        trivyTargets      : ['infra/terraform', 'deploy/k8s'],
        releaseImages     : RELEASE_IMAGES,
        stages            : stages
    ]
}

/**
 * US-22 CA2: decide si se aplica Terraform en un ambiente.
 *   - dev: siempre que haya apply planificado.
 *   - stage: solo si dev quedó desplegado, sano y con E2E en verde (misma compuerta que la app).
 *   - prod: solo con la aprobación manual de US-31 (prodApproval.deploy == true).
 */
Map terraformApplyDecision(Map platformPlan, String envName, Map gates = [:]) {
    if (!TERRAFORM_ENVS.contains(envName)) {
        throw new IllegalArgumentException("Ambiente de Terraform inválido: '${envName}'.")
    }
    if (!(platformPlan?.terraformApply ?: false)) {
        return [env: envName, apply: false, reason: 'No hay cambios de Terraform para aplicar o el build no es de main.']
    }
    if (envName == 'dev') {
        return [env: envName, apply: true, reason: 'Apply automático en dev.']
    }
    if (envName == 'stage') {
        Map results = (gates.deployResults ?: [:]) as Map
        boolean devOk = ['deployDev', 'verifyDev', 'e2eDev'].every { results[it] == 'SUCCESS' }
        return devOk
            ? [env: envName, apply: true, reason: 'dev desplegado, sano y con E2E en verde: apply automático en stage.']
            : [env: envName, apply: false, reason: 'stage no se toca: dev no pasó despliegue, healthchecks y E2E.']
    }
    boolean approved = ((gates.prodApproval ?: [:]).deploy ?: false) as boolean
    return approved
        ? [env: envName, apply: true, reason: "Apply en prod aprobado por ${gates.prodApproval.approver} (US-31)."]
        : [env: envName, apply: false, reason: 'prod espera la aprobación manual de US-31; sin ella no se aplica.']
}

String formatPlatformSummary(Map p) {
    return [
        '=== Plan de plataforma (US-22 / US-38) ===',
        "Terraform: cambios=${p.terraformChanged} plan=${p.runTerraformPlan} apply=${p.terraformApply} archivos=${p.terraformFiles}",
        "Trivy: config=${p.runTrivyConfig} imágenes=${p.runTrivyImages} severidad=${p.trivySeverity}",
        "Etapas: ${p.stages}"
    ].join('\n')
}

return this
