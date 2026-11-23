// jenkins/vars/platformFlow.groovy
// Historias de Usuario: US-22 (Terraform en Jenkins), US-38 (Trivy bloqueante),
// US-39 (despliegue y promoción en Kubernetes) y US-28 (rollback manual).
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
//   - Plataforma de despliegue: 'compose' (Parte 1, nodos EC2 por SSH) o 'k8s'
//     (kubectl apply -k por overlay). El valor por defecto sale de CG_DEPLOY_PLATFORM.
//   - Rollback manual (US-28): solo desde main y sin construir ni desplegar nada nuevo.

import groovy.transform.Field

@Field final String TERRAFORM_ROOT = 'infra/terraform/'
@Field final String K8S_ROOT = 'deploy/k8s/'
@Field final List<String> TERRAFORM_ENVS = ['dev', 'stage', 'prod']
@Field final List<String> TERRAFORM_FILE_SUFFIXES = ['.tf', '.tfvars', '.hcl', '.tftest.hcl', '.sh']
@Field final List<String> DEPLOY_PLATFORMS = ['compose', 'k8s']
@Field final String DEFAULT_DEPLOY_PLATFORM = 'compose'
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

boolean isKubernetesChange(String file) {
    String path = (file ?: '').replace('\\', '/').trim()
    return path.startsWith(K8S_ROOT) && !path.endsWith('.md')
}

/**
 * Resuelve la plataforma de despliegue. `requested` viene del parámetro DEPLOY_PLATFORM
 * ('default' | 'compose' | 'k8s'); `configuredDefault` de la variable global CG_DEPLOY_PLATFORM.
 * Con 'k8s' se exige que existan los overlays de deploy/k8s.
 */
Map resolveDeployPlatform(String requested, String configuredDefault, boolean k8sOverlaysPresent) {
    String asked = (requested ?: 'default').trim().toLowerCase()
    String fallback = (configuredDefault ?: DEFAULT_DEPLOY_PLATFORM).trim().toLowerCase()
    if (!DEPLOY_PLATFORMS.contains(fallback)) {
        throw new IllegalArgumentException("CG_DEPLOY_PLATFORM='${configuredDefault}' no es válido. Valores: ${DEPLOY_PLATFORMS}.")
    }
    String platform = asked == 'default' ? fallback : asked
    if (!DEPLOY_PLATFORMS.contains(platform)) {
        throw new IllegalArgumentException("DEPLOY_PLATFORM='${requested}' no es válido. Valores: default, ${DEPLOY_PLATFORMS.join(', ')}.")
    }
    if (platform == 'k8s' && !k8sOverlaysPresent) {
        throw new IllegalStateException('DEPLOY_PLATFORM=k8s exige deploy/k8s/overlays/{dev,stage,prod} (US-21); no existen en este commit.')
    }
    String source = asked == 'default' ? (configuredDefault ? 'CG_DEPLOY_PLATFORM' : 'valor por defecto') : 'parámetro DEPLOY_PLATFORM'
    return [platform: platform, source: source]
}

/**
 * Plan de etapas de plataforma a partir del plan de multibranchFlow y de la detección
 * de cambios. Es la única fuente de verdad para los `when` de estas etapas.
 *
 * config:
 *   - forceTerraform (boolean): corre plan/apply aunque no cambie infra/terraform.
 *   - deployPlatform (String): parámetro DEPLOY_PLATFORM.
 *   - configuredPlatform (String): variable global CG_DEPLOY_PLATFORM.
 *   - k8sOverlaysPresent (boolean): existen los overlays de US-21.
 *   - enableTrivy (boolean): ENABLE_TRIVY_GATE (por defecto true).
 *   - terraformCredentials (boolean): existe la credencial de AWS de Terraform (por defecto
 *     true). Sin ella no corre ni plan ni apply; con forceTerraform el build falla.
 *   - terraformApplyEnabled (boolean): se permite el apply en main (por defecto true). El
 *     Jenkinsfile lo activa solo con CG_TERRAFORM_APPLY=true.
 */
Map planPlatform(Map plan, Map detection, Map config = [:]) {
    List<String> changed = ((detection?.changedFiles ?: []) as List).collect { it.toString() }
    boolean forceTerraform = (config.forceTerraform ?: false) as boolean
    boolean enableTrivy = (config.containsKey('enableTrivy') ? config.enableTrivy : true) as boolean
    boolean tfCredentials = (config.containsKey('terraformCredentials') ? config.terraformCredentials : true) as boolean
    boolean tfApplyEnabled = (config.containsKey('terraformApplyEnabled') ? config.terraformApplyEnabled : true) as boolean
    boolean heavy = (plan?.runHeavyBuild ?: false) as boolean
    boolean isMain = (plan?.isMainBranch ?: false) as boolean
    boolean autoDeploy = (plan?.autoDeployDev ?: false) as boolean

    List<String> terraformFiles = changed.findAll { isTerraformChange(it) }
    List<String> k8sFiles = changed.findAll { isKubernetesChange(it) }
    boolean terraformChanged = forceTerraform || !terraformFiles.isEmpty()

    Map platform = resolveDeployPlatform(
        (config.deployPlatform ?: 'default') as String,
        (config.configuredPlatform ?: '') as String,
        (config.k8sOverlaysPresent ?: false) as boolean
    )

    // US-22 CA1: plan en cada PR (y en main) que modifique infra/terraform.
    boolean wantsTerraformPlan = terraformChanged && (heavy || forceTerraform)
    if (wantsTerraformPlan && forceTerraform && !tfCredentials) {
        throw new IllegalStateException('FORCE_TERRAFORM=true exige la credencial de AWS de Terraform (US-22); no existe en Jenkins.')
    }
    boolean runTerraformPlan = wantsTerraformPlan && tfCredentials
    // US-22 CA2: apply solo desde main, en el mismo orden de promoción que la aplicación.
    boolean terraformApply = runTerraformPlan && autoDeploy && tfApplyEnabled
    String terraformNote = ''
    if (wantsTerraformPlan && !tfCredentials) {
        terraformNote = 'Sin credencial de AWS de Terraform: se omiten plan y apply.'
    } else if (runTerraformPlan && autoDeploy && !tfApplyEnabled) {
        terraformNote = 'Apply desactivado (CG_TERRAFORM_APPLY no es true): solo plan.'
    }
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
        terraformNote     : terraformNote,
        k8sChanged       : !k8sFiles.isEmpty(),
        runTrivyConfig    : runTrivyConfig,
        runTrivyImages    : runTrivyImages,
        trivySeverity     : TRIVY_BLOCKING_SEVERITY,
        trivyTargets      : ['infra/terraform', 'deploy/k8s'],
        releaseImages     : RELEASE_IMAGES,
        deployPlatform    : platform.platform,
        deployPlatformFrom: platform.source,
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

/**
 * US-28: rollback manual pedido con los parámetros ROLLBACK_ENV / ROLLBACK_TARGET_VERSION.
 * Solo main puede restaurar un ambiente; la versión, si se da, debe ser SemVer (nunca 'latest').
 * Vacío = revisión anterior (k8s) o última versión estable registrada (compose).
 */
Map rollbackRequest(Map context, String envName, String targetVersion) {
    String target = (envName ?: 'none').trim().toLowerCase()
    String version = (targetVersion ?: '').trim()
    if (target == 'none') {
        return [requested: false, allowed: false, env: 'none', version: '', reason: 'No se pidió rollback.']
    }
    if (!TERRAFORM_ENVS.contains(target)) {
        throw new IllegalArgumentException("ROLLBACK_ENV='${envName}' no es válido. Valores: none, ${TERRAFORM_ENVS.join(', ')}.")
    }
    if (version && !(version ==~ /^\d+\.\d+\.\d+(-rc\.\d+)?$/)) {
        throw new IllegalArgumentException("ROLLBACK_TARGET_VERSION='${version}' no es SemVer X.Y.Z (y nunca 'latest').")
    }
    boolean isMain = ((context?.isMainBranch ?: false) as boolean) && !((context?.isPullRequest ?: false) as boolean)
    if (!isMain) {
        return [requested: true, allowed: false, env: target, version: version,
                reason: "Bloqueado: solo main puede hacer rollback; '${context?.branchName ?: 'desconocida'}' no está autorizada."]
    }
    return [requested: true, allowed: true, env: target, version: version, requiresApproval: target == 'prod',
            reason: "Rollback de ${target} a ${version ?: 'la versión anterior'}" + (target == 'prod' ? ' (requiere aprobación de US-31).' : '.')]
}

/**
 * US-28: una ejecución de rollback no construye, no publica ni despliega una versión nueva.
 * Devuelve copias del plan y del plan de plataforma con todo eso apagado.
 */
Map rollbackOnlyPlans(Map plan, Map platformPlan) {
    Map p = new LinkedHashMap(plan ?: [:])
    ['runHeavyBuild', 'runBackendBuild', 'runMobileBuild', 'runSonarAnalysis', 'runQualityGate',
     'autoDeployDev', 'promoteToStage', 'prodRelease', 'deploymentAllowed'].each { p[it] = false }
    p.rollbackOnly = true
    Map pf = new LinkedHashMap(platformPlan ?: [:])
    ['runTerraformPlan', 'terraformApply', 'runTrivyConfig', 'runTrivyImages'].each { pf[it] = false }
    pf.stages = ['Manual Rollback']
    return [plan: p, platform: pf]
}

String formatPlatformSummary(Map p) {
    return [
        '=== Plan de plataforma (US-22 / US-38 / US-39) ===',
        "Terraform: cambios=${p.terraformChanged} plan=${p.runTerraformPlan} apply=${p.terraformApply} archivos=${p.terraformFiles}" +
            (p.terraformNote ? " (${p.terraformNote})" : ''),
        "Trivy: config=${p.runTrivyConfig} imágenes=${p.runTrivyImages} severidad=${p.trivySeverity}",
        "Despliegue: plataforma=${p.deployPlatform} (${p.deployPlatformFrom})",
        "Etapas: ${p.stages}"
    ].join('\n')
}

return this
