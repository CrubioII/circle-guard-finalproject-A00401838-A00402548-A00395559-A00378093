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
// US-13: etapas del despliegue automático a dev y de la promoción condicionada a stage.
// US-44: el escaneo ZAP corre tras los E2E; informa, pero no es compuerta de promoción.
@Field final List<String> CONTINUOUS_DELIVERY_STAGES = [
    'Deploy to dev', 'Verify dev health', 'E2E against dev', 'ZAP Baseline against dev', 'Promote to stage', 'Verify stage health'
]
// Compuertas que deben terminar en SUCCESS, en este orden, antes de promover a stage.
@Field final List<String> PROMOTION_GATES = ['deployDev', 'verifyDev', 'e2eDev']
// US-31: aprobación manual y despliegue verificado a prod, a continuación de stage.
@Field final List<String> PROD_RELEASE_STAGES = ['Approve prod release', 'Deploy to prod', 'Verify prod health']
// Opciones del formulario de aprobación (parámetro DECISION del paso input).
@Field final String PROD_DECISION_APPROVE = 'APROBAR'
@Field final String PROD_DECISION_REJECT = 'RECHAZAR'

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
    // US-13: toda ejecución de main que publica imágenes despliega a dev y, si dev queda sano
    // y los E2E pasan, promueve a stage. Los PR y las ramas feature nunca despliegan.
    boolean autoDeployDev = ((context?.isMainBranch ?: false) as boolean) &&
                            ((context?.canDeployProd ?: false) as boolean) &&
                            !((context?.isPullRequest ?: false) as boolean) &&
                            runHeavyBuild

    List<String> stages = ['Checkout & Context', 'Detect Changed Components']
    if (runHeavyBuild) {
        stages.add('Calculate SemVer')
    }
    if (runBackendBuild) {
        stages.add('Compile & Test Backend')
    }
    // US-10: el análisis y el Quality Gate van tras las pruebas del backend y antes de publicar o desplegar.
    if (runSonarAnalysis) {
        stages.add('SonarQube Analysis')
    }
    if (runQualityGate) {
        stages.add('Quality Gate')
    }
    if (runMobileBuild) {
        stages.add('Compile & Test Web')
        stages.add('E2E Playwright') // US-34
    }
    if (runHeavyBuild) {
        stages.add('Validate Compose Environments')
    }
    if (((context?.isMainBranch ?: false) as boolean) && runHeavyBuild) {
        stages.add('Publish Images to Nexus')
        stages.add('Generate Release Notes & Tag')
    }
    if (autoDeployDev) {
        stages.addAll(CONTINUOUS_DELIVERY_STAGES)
        // US-31 (vía A): la versión que acaba de quedar verificada en stage se ofrece para prod.
        stages.addAll(PROD_RELEASE_STAGES)
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
        autoDeployDev            : autoDeployDev,
        promoteToStage           : autoDeployDev,
        prodRelease              : autoDeployDev,
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
            ? "main autorizado a '${envName}' con aprobación manual obligatoria (la aprobación de producción se implementa en US-31)."
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
 * US-13 (CA2 + CA3): decide si una versión desplegada en dev puede promoverse a stage.
 *
 * `results` mapea cada compuerta a su resultado: 'SUCCESS', 'FAILURE', 'SKIPPED' o 'NOT_RUN'.
 *   deployDev  -> despliegue de la versión en dev
 *   verifyDev  -> healthchecks de servicios y middleware en dev
 *   e2eDev     -> flujos E2E contra dev
 * Solo se promueve si las tres terminaron en SUCCESS. La primera compuerta no exitosa
 * explica el bloqueo, que queda registrado en reports/ci/promotion-stage.json.
 */
Map promotionDecision(Map results, Map config = [:]) {
    String version = config.version ?: ''
    Map normalized = PROMOTION_GATES.collectEntries { String gate ->
        [(gate): ((results?.get(gate) ?: 'NOT_RUN') as String).toUpperCase()]
    }
    List<String> blockedBy = PROMOTION_GATES.findAll { String gate -> normalized[gate] != 'SUCCESS' }
    boolean promote = blockedBy.isEmpty()

    Map gateLabels = [deployDev: 'despliegue en dev', verifyDev: 'healthchecks de dev', e2eDev: 'pruebas E2E contra dev']
    String reason
    if (promote) {
        reason = "Versión ${version ?: '?'} promovida a stage: despliegue, healthchecks y E2E de dev exitosos."
    } else {
        String first = blockedBy[0]
        reason = "Promoción a stage detenida: ${gateLabels[first]} = ${normalized[first]}" +
                 (version ? " (versión ${version})." : '.')
    }

    return [
        targetEnv : 'stage',
        version   : version,
        promote   : promote,
        status    : promote ? 'PROMOTED' : 'BLOCKED',
        gates     : normalized,
        blockedBy : blockedBy,
        reason    : reason
    ]
}

/**
 * US-31: lista de aprobadores de prod a partir de CG_PROD_APPROVERS (IDs de usuario de Jenkins
 * separados por comas o espacios). Vacía = no hay quién apruebe. Se exigen IDs de usuario (no grupos)
 * porque prodApprovalDecision valida que quien responde esté en la lista.
 */
List<String> parseProdApprovers(String raw) {
    return (raw ?: '').split(/[,\s]+/).collect { it.trim() }.findAll { !it.isEmpty() }.unique()
}

/**
 * US-31 (CA1 + CA2): interpreta el resultado de la compuerta de aprobación manual a prod.
 *
 * `response` es lo que devuelve el paso `input` (parámetros + submitterParameter):
 *   DECISION (APROBAR | RECHAZAR), VERSION, COMMENT, APPROVER.
 * `config`:
 *   outcome          'SUBMITTED' (se respondió el formulario) | 'TIMEOUT' | 'ABORTED' | 'NOT_CONFIGURED'
 *   validatedVersion versión que pasó dev + E2E + stage en esta ejecución (la única elegible)
 *   approvers        aprobadores configurados (lista ya parseada)
 *   abortedBy        usuario que abortó, si Jenkins lo informó
 *
 * Solo `status == 'APPROVED'` habilita el despliegue. Cualquier otro resultado deja prod
 * intacto y explica el motivo, que queda en reports/ci/prod-approval.json (CA2).
 */
Map prodApprovalDecision(Map response, Map config = [:]) {
    String outcome = ((config.outcome ?: 'SUBMITTED') as String).toUpperCase()
    String validated = (config.validatedVersion ?: '') as String
    List<String> approvers = (config.approvers ?: []) as List<String>
    String decision = ((response?.DECISION ?: '') as String).trim().toUpperCase()
    String version = ((response?.VERSION ?: '') as String).trim()
    String comment = ((response?.COMMENT ?: '') as String).trim()
    String approver = ((response?.APPROVER ?: '') as String).trim()

    Map base = [
        targetEnv       : 'prod',
        validatedVersion: validated,
        version         : version ?: validated,
        approver        : approver,
        comment         : comment,
        approvers       : approvers,
        outcome         : outcome
    ]
    Closure<Map> result = { String status, boolean deploy, String reason ->
        base + [status: status, deploy: deploy, reason: reason]
    }

    if (outcome == 'NOT_CONFIGURED' || approvers.isEmpty()) {
        return result('NOT_CONFIGURED', false,
            'Release a prod omitido: no hay aprobadores configurados (variable global CG_PROD_APPROVERS).')
    }
    if (!validated) {
        return result('INVALID', false, 'No hay una versión validada en stage en esta ejecución; no se ofrece release a prod.')
    }
    if (outcome == 'TIMEOUT') {
        return result('TIMEOUT', false, "Release a prod de ${validated} expiró sin respuesta de los aprobadores.")
    }
    if (outcome == 'ABORTED') {
        String who = config.abortedBy ? " por ${config.abortedBy}" : ''
        return result('ABORTED', false, "Release a prod de ${validated} abortado${who}.")
    }
    if (!approver) {
        return result('INVALID', false, 'La respuesta de aprobación no identifica a quien decidió (submitterParameter vacío).')
    }
    // Defensa en profundidad: Jenkins deja responder cualquier `input` a los administradores aunque no
    // estén en `submitter` (con loggedInUsersCanDoAnything lo son todos). Solo cuenta quien esté en la lista.
    if (!approvers.any { String allowed -> allowed.equalsIgnoreCase(approver) }) {
        return result('INVALID', false,
            "El usuario '${approver}' no está autorizado para decidir releases a prod (CG_PROD_APPROVERS: ${approvers.join(', ')}).")
    }
    if (decision == PROD_DECISION_REJECT) {
        return result('REJECTED', false, "Release a prod de ${version ?: validated} RECHAZADO por ${approver}" +
            (comment ? ": ${comment}" : '.'))
    }
    if (decision != PROD_DECISION_APPROVE) {
        return result('INVALID', false, "Decisión desconocida '${response?.DECISION}'.")
    }
    if (version != validated) {
        return result('INVALID', false,
            "La versión seleccionada '${version}' no es la validada en stage (${validated}); no se despliega.")
    }
    if (comment.length() < 3) {
        return result('INVALID', false, 'La aprobación a prod exige un comentario o ID de RFC (política de cambios).')
    }
    return result('APPROVED', true, "Release a prod de ${version} APROBADO por ${approver}: ${comment}")
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
        "Despliegue auto (dev) : ${plan?.autoDeployDev} | Promoción a stage tras E2E: ${plan?.promoteToStage}",
        "Release a prod        : ${plan?.prodRelease} (requiere aprobación manual, US-31)",
        "Etapas a ejecutar     : ${(plan?.stages ?: []).join(' -> ')}",
        '====================================================='
    ].join('\n')
}

return this
