// jenkins/vars/notifyPipeline.groovy
// Historia de Usuario: US-14 (SCRUM-26) — CA1 / Subtarea SCRUM-70
// Propósito: Notificar el resultado del pipeline de CircleGuard en el canal #pipeline
// de Discord (webhook guardado como credencial "Secret text" de Jenkins). El mensaje
// incluye rama, commit, autor, versión SemVer, etapa que falló y enlace directo al log.
//
// Reglas:
// - La URL del webhook NUNCA se escribe en el repositorio ni en el log: se inyecta con
//   withCredentials y curl la lee desde la variable de entorno.
// - Una notificación jamás cambia el resultado del build: cualquier error (credencial
//   ausente, Discord caído) se registra como advertencia.
// - Se notifica siempre FAILURE, ABORTED y UNSTABLE; SUCCESS solo en main (entregas) o
//   cuando el build se recupera de un fallo anterior, para no llenar el canal de ruido.
//
// Uso (bloque post del Jenkinsfile):
//   notifyPipeline(status: currentBuild.currentResult, flow: flow,
//                  version: versionMap.APP_VERSION, failedStage: pipelineTrack.stage)
//
// Modo dry-run (sin enviar nada): dryRun: true o env.NOTIFY_PIPELINE_DRY_RUN=true.
//
// Nota: este archivo no usa @Field para poder cargarse también con `load` desde el
// workspace (ver Jenkinsfile): así un Pull Request prueba su propia versión del paso
// aunque la Shared Library global apunte a main.

/**
 * Construye y envía la notificación.
 *
 * Parámetros:
 * - status (String): SUCCESS | FAILURE | ABORTED | UNSTABLE (por defecto currentBuild.currentResult).
 * - flow (Map): contexto de multibranchFlow.collectContext().
 * - version (String): versión SemVer calculada (US-12); vacío si el build no la calculó.
 * - failedStage (String): última etapa iniciada; en un fallo es la etapa que falló.
 * - previousStatus (String): resultado del build anterior (detecta recuperaciones).
 * - commit / author / commitMessage (String): overrides; por defecto se leen de git.
 * - buildUrl, jobName, buildNumber, durationMs: overrides de los datos de Jenkins.
 * - details (String): texto adicional (p. ej. el rollback ejecutado).
 * - credentialsId (String): credencial Secret text con la URL del webhook (por defecto 'discord-webhook').
 * - force (Boolean): notifica aunque la política diga que no hace falta.
 * - dryRun (Boolean): no envía; devuelve el payload calculado.
 */
Map call(Map config) {
    Map info = collectBuildInfo(config)
    Map decision = shouldNotify(info.status, info.isMainBranch, info.previousStatus, config.force)
    boolean dryRun = config.containsKey('dryRun')
        ? (config.dryRun as boolean)
        : (env?.NOTIFY_PIPELINE_DRY_RUN == 'true')

    Map payload = buildPayload(info)
    Map result = [notify: decision.notify, reason: decision.reason, dryRun: dryRun, payload: payload, sent: false]

    if (!decision.notify) {
        echo "[notifyPipeline] No se notifica: ${decision.reason}"
        return result
    }
    if (dryRun) {
        echo "[notifyPipeline][dry-run] ${groovy.json.JsonOutput.toJson(payload)}"
        return result
    }
    return result + sendToDiscord(payload, (config.credentialsId ?: 'discord-webhook').toString())
}

/**
 * Política de notificación (pura, sin efectos): devuelve [notify: Boolean, reason: String].
 * Todos los parámetros son Object y sin valores por defecto: el intérprete CPS de Jenkins no
 * resuelve bien métodos con parámetros primitivos o por defecto en scripts cargados con `load`.
 */
Map shouldNotify(Object rawStatus, Object isMainBranch, Object rawPreviousStatus, Object force) {
    String status = normalizeStatus(rawStatus)
    String previous = (rawPreviousStatus ?: '').toString().trim().toUpperCase()
    if (force as boolean) {
        return [notify: true, reason: 'Notificación forzada.']
    }
    if (status != 'SUCCESS') {
        return [notify: true, reason: "El build terminó en ${status}."]
    }
    if (previous && previous != 'SUCCESS') {
        return [notify: true, reason: "El build se recuperó (el anterior terminó en ${previous})."]
    }
    if (isMainBranch as boolean) {
        return [notify: true, reason: 'Build exitoso de main (entrega).']
    }
    return [notify: false, reason: 'Build exitoso en una rama o PR sin fallo previo.']
}

/**
 * Reúne rama, commit, autor, versión, etapa y enlaces del build. Los overrides de
 * config tienen prioridad; lo que falte se lee de env, currentBuild y git.
 */
Map collectBuildInfo(Map config) {
    Map flow = (config.flow instanceof Map ? config.flow : [:]) as Map
    String status = normalizeStatus(config.status ?: safeCurrentResult())
    String previousStatus = (config.previousStatus ?: safePreviousResult() ?: '').toString()
    boolean isPullRequest = (flow.isPullRequest ?: false) as boolean || !(env?.CHANGE_ID ?: '').toString().trim().isEmpty()
    boolean isMainBranch = flow.containsKey('isMainBranch')
        ? (flow.isMainBranch as boolean)
        : (!isPullRequest && (env?.BRANCH_NAME ?: '') == 'main')

    Map commitInfo = [
        sha    : (config.commit ?: '').toString(),
        author : (config.author ?: '').toString(),
        message: (config.commitMessage ?: '').toString()
    ]
    if (!commitInfo.sha || !commitInfo.author || !commitInfo.message) {
        Map fromGit = readCommitFromGit()
        commitInfo.sha = commitInfo.sha ?: fromGit.sha
        commitInfo.author = commitInfo.author ?: (env?.CHANGE_AUTHOR_DISPLAY_NAME ?: env?.CHANGE_AUTHOR ?: fromGit.author)
        commitInfo.message = commitInfo.message ?: fromGit.message
    }

    String buildUrl = (config.buildUrl ?: env?.BUILD_URL ?: '').toString()
    return [
        status        : status,
        previousStatus: previousStatus,
        isMainBranch  : isMainBranch,
        isPullRequest : isPullRequest,
        branch        : (flow.branchName ?: env?.CHANGE_BRANCH ?: env?.BRANCH_NAME ?: 'desconocida').toString(),
        pullRequest   : isPullRequest ? (env?.CHANGE_ID ?: flow.changeId ?: '').toString() : '',
        pullRequestUrl: isPullRequest ? (env?.CHANGE_URL ?: '').toString() : '',
        targetBranch  : isPullRequest ? (env?.CHANGE_TARGET ?: 'main').toString() : '',
        commit        : commitInfo.sha ?: 'desconocido',
        author        : commitInfo.author ?: 'desconocido',
        commitMessage : commitInfo.message ?: '',
        version       : (config.version ?: '').toString().trim(),
        failedStage   : (config.failedStage ?: '').toString().trim(),
        details       : (config.details ?: '').toString().trim(),
        jobName       : (config.jobName ?: env?.JOB_NAME ?: 'circleguard-monorepo').toString(),
        buildNumber   : (config.buildNumber ?: env?.BUILD_NUMBER ?: '?').toString(),
        buildUrl      : buildUrl,
        logUrl        : buildUrl ? "${buildUrl}console" : '',
        durationMs    : config.durationMs != null ? (config.durationMs as long) : safeDuration()
    ]
}

/**
 * Mensaje de Discord (webhook API: content + embeds). Función pura para poder probarla.
 */
Map buildPayload(Map info) {
    String status = normalizeStatus(info.status)
    Map style = statusStyle(status, (info.previousStatus ?: '').toString())
    String shortSha = shortCommit(info.commit)
    String versionText = info.version ? "`${info.version}`" : 'sin versión (no se calculó en este build)'

    List<Map> fields = []
    fields << field('Rama', "`${info.branch}`", true)
    if (info.pullRequest) {
        String prText = info.pullRequestUrl ? "[#${info.pullRequest}](${info.pullRequestUrl})" : "#${info.pullRequest}"
        fields << field('Pull Request', "${prText} → `${info.targetBranch}`", true)
    }
    fields << field('Versión', versionText, true)
    fields << field('Commit', info.commitMessage ? "`${shortSha}` ${firstLine(info.commitMessage)}" : "`${shortSha}`", false)
    fields << field('Autor', info.author.toString(), true)
    if (status != 'SUCCESS') {
        fields << field('Etapa fallida', info.failedStage ? "`${info.failedStage}`" : 'no identificada (revisar el log)', true)
    }
    if (info.durationMs) {
        fields << field('Duración', formatDuration(info.durationMs as long), true)
    }
    if (info.details) {
        fields << field('Detalle', info.details.toString(), false)
    }
    if (info.logUrl) {
        fields << field('Log', "[Abrir el log del build #${info.buildNumber}](${info.logUrl})", false)
    }

    String title = "${style.icon} CircleGuard CI — ${style.label}: ${info.jobName} #${info.buildNumber}"
    Map embed = [
        title      : truncate(title, 256),
        description: truncate(style.description.toString(), 4096),
        color      : style.color,
        fields     : fields
    ]
    if (info.logUrl) {
        embed.url = info.logUrl
    }
    return [
        username        : 'Jenkins CircleGuard',
        content         : truncate("${style.icon} **${style.label}** en `${info.branch}` (${shortSha})", 2000),
        embeds          : [embed],
        allowed_mentions: [parse: []]
    ]
}

/** Envía el payload con curl; la URL del webhook solo existe dentro de withCredentials. */
Map sendToDiscord(Object payload, Object credentialsId) {
    String payloadFile = 'reports/ci/discord-notification.json'
    try {
        sh 'mkdir -p reports/ci'
        writeFile file: payloadFile, text: groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload))
        String httpCode = ''
        withCredentials([string(credentialsId: credentialsId, variable: 'DISCORD_WEBHOOK_URL')]) {
            // Comillas simples: Groovy no interpola el secreto; lo expande el shell.
            httpCode = sh(
                script: 'curl -sS -o /dev/null -w "%{http_code}" --max-time 20 -H "Content-Type: application/json" -X POST --data @' +
                        payloadFile + ' "$DISCORD_WEBHOOK_URL" || true',
                returnStdout: true
            ).trim()
        }
        boolean sent = httpCode ==~ /^2\d\d$/
        if (sent) {
            echo "[notifyPipeline] Notificación enviada a Discord (HTTP ${httpCode})."
        } else {
            echo "[notifyPipeline] Advertencia: Discord respondió HTTP '${httpCode}'; el build no cambia de estado."
        }
        archiveArtifacts artifacts: payloadFile, allowEmptyArchive: true
        return [sent: sent, httpCode: httpCode]
    } catch (Exception exception) {
        echo "[notifyPipeline] Advertencia: no se pudo notificar en Discord (¿existe la credencial '${credentialsId}'?): ${exception.message}"
        return [sent: false, error: exception.message]
    }
}

String normalizeStatus(Object rawStatus) {
    String value = (rawStatus ?: 'SUCCESS').toString().trim().toUpperCase()
    if (['SUCCESS', 'FAILURE', 'ABORTED', 'UNSTABLE', 'NOT_BUILT'].contains(value)) {
        return value
    }
    return 'FAILURE'
}

Map statusStyle(Object status, Object previousStatus) {
    String previous = (previousStatus ?: '').toString()
    switch ((status ?: '').toString()) {
        case 'SUCCESS':
            boolean recovered = previous && previous.toUpperCase() != 'SUCCESS'
            return [
                icon       : '✅',
                label      : recovered ? 'RECUPERADO' : 'ÉXITO',
                color      : 3066993,
                description: recovered
                    ? "El pipeline vuelve a estar en verde (el build anterior terminó en ${previous.toUpperCase()})."
                    : 'El pipeline terminó correctamente.'
            ]
        case 'UNSTABLE':
            return [icon: '⚠️', label: 'INESTABLE', color: 15105570,
                    description: 'El pipeline terminó con pruebas fallidas o advertencias.']
        case 'ABORTED':
        case 'NOT_BUILT':
            return [icon: '⏹️', label: 'ABORTADO', color: 9807270,
                    description: 'El pipeline fue abortado (manualmente, por tiempo o por un build más nuevo).']
        default:
            return [icon: '❌', label: 'FALLÓ', color: 15158332,
                    description: 'El pipeline falló. Revisa la etapa fallida y el log.']
    }
}

private Map field(Object name, Object value, Object inline) {
    return [name: truncate(name, 256), value: truncate(value ?: '-', 1024), inline: inline as boolean]
}

private String truncate(Object value, Object max) {
    String text = (value ?: '').toString()
    int limit = max as int
    return text.length() > limit ? text.substring(0, limit - 3) + '...' : text
}

private String firstLine(Object message) {
    String text = (message ?: '').toString().trim()
    int newline = text.indexOf('\n')
    return newline >= 0 ? text.substring(0, newline).trim() : text
}

private String shortCommit(Object sha) {
    String value = (sha ?: '').toString().trim()
    return value.length() > 7 && value ==~ /^[0-9a-fA-F]+$/ ? value.substring(0, 7) : (value ?: 'desconocido')
}

String formatDuration(Object durationMs) {
    long totalSeconds = (long) ((durationMs as long) / 1000L)
    long minutes = (long) (totalSeconds / 60L)
    long seconds = totalSeconds % 60L
    return minutes > 0 ? "${minutes} min ${seconds} s" : "${seconds} s"
}

/**
 * Commit del build. En un PR Jenkins construye "Merge commit '<main>' into HEAD";
 * en ese caso el commit del autor es HEAD^1 (igual criterio que publishBuildStatus).
 */
private Map readCommitFromGit() {
    try {
        String raw = sh(
            script: '''
                ref=HEAD
                case "$(git log -1 --pretty=%s HEAD 2>/dev/null || true)" in
                    "Merge commit '"*"' into HEAD") ref=HEAD^1 ;;
                esac
                git log -1 --pretty=format:'%H%n%an%n%s' "$ref" 2>/dev/null || true
            ''',
            returnStdout: true
        ).trim()
        List<String> lines = raw ? (raw.split('\n') as List<String>) : []
        return [
            sha    : lines.size() > 0 ? lines[0].trim() : '',
            author : lines.size() > 1 ? lines[1].trim() : '',
            message: lines.size() > 2 ? lines[2].trim() : ''
        ]
    } catch (Exception ignored) {
        return [sha: (env?.GIT_COMMIT ?: '').toString(), author: '', message: '']
    }
}

private String safeCurrentResult() {
    try {
        return currentBuild?.currentResult?.toString()
    } catch (Exception ignored) {
        return null
    }
}

private String safePreviousResult() {
    try {
        return currentBuild?.previousBuild?.result?.toString()
    } catch (Exception ignored) {
        return null
    }
}

private long safeDuration() {
    try {
        return (currentBuild?.duration ?: 0L) as long
    } catch (Exception ignored) {
        return 0L
    }
}

return this
