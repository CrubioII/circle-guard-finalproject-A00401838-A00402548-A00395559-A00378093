// jenkins/vars/multibranchFlow.groovy
// Historia de Usuario: US-30 (SCRUM-113 / SCRUM-56)
// Propósito: Resolver el contexto de ejecución de un Jenkinsfile Multibranch
// (rama vs. Pull Request), calcular el plan de etapas a ejecutar y bloquear
// cualquier despliegue a ambientes desde un Pull Request.

import groovy.transform.Field

@Field final List<String> SUPPORTED_TARGET_ENVS = ['none', 'dev', 'stage', 'prod']
@Field final List<String> PRODUCTION_TARGET_ENVS = ['prod']
@Field final String STATUS_CONTEXT_PR = 'continuous-integration/jenkins/pr-head'
@Field final String STATUS_CONTEXT_MAIN = 'continuous-integration/jenkins/main'

/**
 * Punto de entrada por defecto: devuelve el contexto normalizado de la ejecución.
 * Puede recibir overrides por parámetro para pruebas reproducibles sin Jenkins.
 */
Map call(Map config = [:]) {
    return collectContext(config)
}

/**
 * Construye el contexto de la ejecución a partir de las variables que inyecta
 * el GitHub Branch Source plugin en un job Multibranch:
 *   - BRANCH_NAME: nombre de la rama o "PR-<id>" en builds de Pull Request.
 *   - CHANGE_ID / CHANGE_TARGET / CHANGE_BRANCH / CHANGE_FORK: metadatos del PR.
 */
Map collectContext(Map config = [:]) {
    String branchName = config.containsKey('branchName') ? (config.branchName ?: '') : (env?.BRANCH_NAME ?: 'local')
    String changeId = config.containsKey('changeId') ? (config.changeId ?: '') : (env?.CHANGE_ID ?: '')
    String changeTarget = config.containsKey('changeTarget') ? (config.changeTarget ?: '') : (env?.CHANGE_TARGET ?: '')
    String changeBranch = config.containsKey('changeBranch') ? (config.changeBranch ?: '') : (env?.CHANGE_BRANCH ?: '')
    String changeFork = config.containsKey('changeFork') ? (config.changeFork ?: '') : (env?.CHANGE_FORK ?: '')

    // Se delega en pipelineUtils (US-09) para no duplicar la semántica PR/main.
    Map base = pipelineUtils.call(
        branchName: branchName,
        changeId: changeId,
        changeTarget: changeTarget
    )

    boolean isPullRequest = (base.isPullRequest ?: false) as boolean
    String statusContext = isPullRequest ? STATUS_CONTEXT_PR : STATUS_CONTEXT_MAIN

    return base + [
        changeBranch    : changeBranch ?: '',
        changeFork      : changeFork ?: '',
        isForkPullRequest: isPullRequest && !changeFork.trim().isEmpty(),
        statusContext   : statusContext
    ]
}

/**
 * Calcula qué etapas debe ejecutar el Jenkinsfile para esta combinación de
 * contexto + detección de cambios + TARGET_ENV solicitado.
 *
 * El mapa devuelto es la única fuente de verdad para los bloques `when` del
 * Jenkinsfile, de modo que la lógica sea comprobable sin una instancia Jenkins.
 */
Map planPipeline(Map context, Map detection, Map config = [:]) {
    String targetEnv = normalizeTargetEnv(config.containsKey('targetEnv') ? config.targetEnv : 'none')
    boolean forceFullBuild = (config.containsKey('forceFullBuild') ? config.forceFullBuild : false) as boolean

    List<String> backendServices = (detection?.backendServices ?: []) as List<String>
    boolean mobileChanged = (detection?.mobileChanged ?: false) as boolean
    boolean skipCiBuild = (detection?.skipCiBuild ?: false) as boolean
    boolean fullBuild = (detection?.fullBuild ?: false) as boolean

    boolean runHeavyBuild = !skipCiBuild
    boolean runBackendBuild = runHeavyBuild && !backendServices.isEmpty()
    boolean runMobileBuild = runHeavyBuild && mobileChanged
    boolean enableSonar = (config.containsKey('enableSonar') ? config.enableSonar : true) as boolean
    boolean runSonarAnalysis = runBackendBuild && enableSonar
    boolean runQualityGate = runSonarAnalysis

    Map deployment = deploymentDecision(context, targetEnv)

    List<String> stages = ['Checkout & Context', 'Detect Changed Components']
    if (runBackendBuild) {
        stages.add('Compile & Test Backend')
    }
    if (runMobileBuild) {
        stages.add('Compile & Test Web')
    }
    if (runSonarAnalysis) {
        stages.add('SonarQube Analysis')
    }
    if (runQualityGate) {
        stages.add('Quality Gate')
    }
    if (deployment.allowed) {
        stages.add('Release Gate')
    }

    return [
        branchName               : context?.branchName ?: '',
        isPullRequest            : (context?.isPullRequest ?: false) as boolean,
        isMainBranch             : (context?.isMainBranch ?: false) as boolean,
        canDeployProd            : (context?.canDeployProd ?: false) as boolean,
        statusContext            : context?.statusContext ?: STATUS_CONTEXT_MAIN,
        targetEnv                : targetEnv,
        forceFullBuild           : forceFullBuild,
        fullBuild                : fullBuild,
        skipDocsOnly             : skipCiBuild,
        runHeavyBuild            : runHeavyBuild,
        runBackendBuild          : runBackendBuild,
        runMobileBuild           : runMobileBuild,
        runSonarAnalysis         : runSonarAnalysis,
        runQualityGate           : runQualityGate,
        backendServices          : backendServices,
        mobileChanged            : mobileChanged,
        deploymentRequested      : targetEnv != 'none',
        deploymentAllowed        : deployment.allowed as boolean,
        deploymentRequiresApproval: deployment.requiresApproval as boolean,
        deploymentReason         : deployment.reason,
        stages                   : stages
    ]
}

/**
 * Decide si el contexto actual puede desplegar al ambiente solicitado.
 * Regla dura de US-30: ningún Pull Request ni rama distinta de main puede desplegar.
 */
Map deploymentDecision(Map context, String targetEnv) {
    String envName = normalizeTargetEnv(targetEnv)

    if (envName == 'none') {
        return [
            targetEnv       : 'none',
            allowed         : false,
            requiresApproval: false,
            reason          : 'No se solicitó despliegue (TARGET_ENV=none).'
        ]
    }

    if ((context?.isPullRequest ?: false) as boolean) {
        String prId = context?.changeId ?: '?'
        return [
            targetEnv       : envName,
            allowed         : false,
            requiresApproval: false,
            reason          : "Bloqueado: el Pull Request #${prId} no puede desplegar a '${envName}'. " +
                              'Los PR solo ejecutan compilación, pruebas y publicación de estado; ' +
                              'el despliegue se reserva para la rama main.'
        ]
    }

    if (!((context?.isMainBranch ?: false) as boolean)) {
        return [
            targetEnv       : envName,
            allowed         : false,
            requiresApproval: false,
            reason          : "Bloqueado: solo la rama main puede desplegar; la rama '${context?.branchName ?: 'desconocida'}' no está autorizada a '${envName}'."
        ]
    }

    if (!((context?.canDeployProd ?: false) as boolean)) {
        return [
            targetEnv       : envName,
            allowed         : false,
            requiresApproval: false,
            reason          : "Bloqueado: el contexto actual no tiene habilitado el despliegue (canDeployProd=false) hacia '${envName}'."
        ]
    }

    boolean requiresApproval = PRODUCTION_TARGET_ENVS.contains(envName)
    return [
        targetEnv       : envName,
        allowed         : true,
        requiresApproval: requiresApproval,
        reason          : requiresApproval
            ? "main autorizado a '${envName}' con aprobación manual obligatoria (la promoción gobernada se implementa en US-13)."
            : "main autorizado a '${envName}'."
    ]
}

/**
 * Guarda explícita que aborta el build cuando el plan intenta un despliegue no
 * permitido. Se invoca desde el Jenkinsfile antes de la etapa Release Gate.
 */
Map requireDeploymentAllowed(Map context, String targetEnv) {
    Map decision = deploymentDecision(context, targetEnv)
    if (!decision.allowed) {
        error("Despliegue rechazado por multibranchFlow: ${decision.reason}")
    }
    return decision
}

/**
 * Normaliza y valida el ambiente destino. Falla rápido ante valores inválidos
 * para evitar que un parámetro mal escrito se interprete como "sin despliegue".
 */
String normalizeTargetEnv(String targetEnv) {
    String value = (targetEnv ?: 'none').toString().trim().toLowerCase()
    if (!SUPPORTED_TARGET_ENVS.contains(value)) {
        throw new IllegalArgumentException(
            "TARGET_ENV invalido: '${targetEnv}'. Valores permitidos: ${SUPPORTED_TARGET_ENVS.join(', ')}."
        )
    }
    return value
}

/**
 * Resumen legible del plan para la consola de Jenkins.
 */
String formatPlanSummary(Map plan) {
    return [
        '=== CircleGuard Multibranch Pipeline Plan (US-30) ===',
        "Rama                  : ${plan?.branchName}",
        "Pull Request          : ${plan?.isPullRequest}",
        "Rama main             : ${plan?.isMainBranch}",
        "Contexto de estado    : ${plan?.statusContext}",
        "Build pesado          : ${plan?.runHeavyBuild}",
        "Backend afectado      : ${(plan?.backendServices ?: []).isEmpty() ? 'ninguno' : plan.backendServices.join(', ')}",
        "Cliente web (mobile)  : ${plan?.mobileChanged}",
        "Ambiente solicitado   : ${plan?.targetEnv}",
        "Despliegue permitido  : ${plan?.deploymentAllowed} (${plan?.deploymentReason})",
        "Etapas a ejecutar     : ${(plan?.stages ?: []).join(' -> ')}",
        '====================================================='
    ].join('\n')
}

return this
