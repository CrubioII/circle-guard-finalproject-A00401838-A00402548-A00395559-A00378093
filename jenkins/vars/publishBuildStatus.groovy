// jenkins/vars/publishBuildStatus.groovy
// Historia de Usuario: US-30 (SCRUM-113 / SCRUM-56)
// Propósito: Publicar el estado del build de CircleGuard en GitHub (Commit Status API)
// para los contextos 'continuous-integration/jenkins/pr-head' y
// 'continuous-integration/jenkins/main'. Tolera la ausencia del plugin de GitHub
// y soporta un modo dry-run para validación reproducible sin Jenkins.

import groovy.transform.Field

@Field final String STATUS_CONTEXT_PR = 'continuous-integration/jenkins/pr-head'
@Field final String STATUS_CONTEXT_MAIN = 'continuous-integration/jenkins/main'
@Field final int MAX_DESCRIPTION_LENGTH = 140

/**
 * Publica un estado de commit en GitHub.
 *
 * Parámetros soportados:
 * - state (String): PENDING | SUCCESS | FAILURE | ERROR (ABORTED se mapea a ERROR).
 * - flow (Map): contexto devuelto por multibranchFlow.collectContext().
 * - description (String): texto corto (se recorta a 140 caracteres).
 * - statusContext (String): override del contexto publicado.
 * - sha (String): commit a reportar (por defecto env.CHANGE_COMMIT en PRs o env.GIT_COMMIT).
 * - repository (String): 'owner/repo' o account/repo por separado.
 * - credentialsId (String): credencial de Jenkins con el PAT de GitHub.
 * - dryRun (Boolean): si es true no invoca la API y devuelve el payload calculado.
 */
Map call(Map config = [:]) {
    Map flow = (config.flow instanceof Map ? config.flow : [:]) as Map
    String state = normalizeState(config.state)
    String statusContext = config.statusContext ?: flow.statusContext ?: defaultStatusContext(flow)
    String description = normalizeDescription(config.description ?: "CircleGuard CI ${state.toLowerCase()}")
    String targetUrl = config.targetUrl ?: (env?.BUILD_URL ?: '')
    String sha = config.sha ?: (env?.CHANGE_COMMIT ?: env?.GIT_COMMIT ?: '')
    Map repository = resolveRepository(config, flow)
    boolean dryRun = config.containsKey('dryRun')
        ? (config.dryRun as boolean)
        : (env?.PUBLISH_BUILD_STATUS_DRY_RUN == 'true')

    Map payload = [
        state             : state,
        context           : statusContext,
        description       : description,
        targetUrl         : targetUrl,
        sha               : sha,
        account           : repository.account,
        repo              : repository.name,
        repository        : repository.fullName,
        resolvedRepository: repository.resolved,
        dryRun            : dryRun
    ]

    if (dryRun) {
        echo "[publishBuildStatus][dry-run] ${payload}"
        return payload + [published: false]
    }

    if (!(repository.resolved as boolean) || !sha) {
        echo "[publishBuildStatus] Advertencia: no se pudo resolver repositorio/commit de GitHub; se omite la publicación del estado ${state}."
        return payload + [published: false, skipped: true]
    }

    try {
        githubNotify(
            account: repository.account,
            repo: repository.name,
            sha: sha,
            context: statusContext,
            description: description,
            status: state,
            targetUrl: targetUrl,
            credentialsId: (config.credentialsId ?: 'github-credentials')
        )
        echo "[publishBuildStatus] Estado '${state}' publicado en GitHub para ${repository.fullName}@${sha} (${statusContext})."
        return payload + [published: true]
    } catch (Exception exception) {
        // El pipeline no debe fallar por una limitación del plugin/credencial de GitHub.
        echo "[publishBuildStatus] Advertencia: no se pudo publicar el estado '${state}' en GitHub: ${exception.message}"
        return payload + [published: false, error: exception.message]
    }
}

/**
 * Normaliza el estado de GitHub. Cualquier valor no reconocido se publica como
 * ERROR para que el fallo sea visible y no quede silenciosamente en PENDING.
 */
String normalizeState(Object rawState) {
    String value = (rawState ?: 'PENDING').toString().trim().toUpperCase()
    switch (value) {
        case 'SUCCESS':
            return 'SUCCESS'
        case 'FAILURE':
            return 'FAILURE'
        case 'PENDING':
            return 'PENDING'
        case 'ERROR':
        case 'ABORTED':
            return 'ERROR'
        default:
            echo "[publishBuildStatus] Advertencia: estado desconocido '${rawState}'; se publicara ERROR."
            return 'ERROR'
    }
}

/**
 * GitHub limita la descripción a 140 caracteres y no admite saltos de línea.
 */
String normalizeDescription(Object rawDescription) {
    String value = (rawDescription ?: '').toString().replaceAll(/\s+/, ' ').trim()
    if (value.isEmpty()) {
        return 'CircleGuard CI'
    }
    if (value.length() > MAX_DESCRIPTION_LENGTH) {
        return value.substring(0, MAX_DESCRIPTION_LENGTH - 3) + '...'
    }
    return value
}

/**
 * Contexto por defecto: PRs usan 'pr-head' (requerido por la protección de main
 * definida en US-02) y main usa un contexto propio.
 */
String defaultStatusContext(Map flow) {
    boolean isPullRequest = (flow?.isPullRequest ?: false) as boolean || !(env?.CHANGE_ID ?: '').toString().trim().isEmpty()
    return isPullRequest ? STATUS_CONTEXT_PR : STATUS_CONTEXT_MAIN
}

/**
 * Resuelve owner/repo a partir de overrides explícitos, env.GITHUB_REPOSITORY o
 * env.GIT_URL (HTTPS o SSH). Devuelve resolved=false si no es un remoto GitHub.
 */
Map resolveRepository(Map config = [:], Map flow = [:]) {
    String explicitRepository = (config.repository ?: env?.CIRCLEGUARD_REPOSITORY ?: env?.GITHUB_REPOSITORY ?: '').toString().trim()
    if (explicitRepository.contains('/')) {
        List<String> parts = explicitRepository.replaceAll(/\.git$/, '').split('/')
        if (parts.size() >= 2) {
            return buildRepository(parts[0], parts[1], true)
        }
    }

    if (config.account && config.repo) {
        return buildRepository(config.account.toString(), config.repo.toString(), true)
    }

    return parseGitHubRepository(env?.GIT_URL ?: '')
}

/**
 * Extrae owner/repo de https://github.com/owner/repo.git,
 * git@github.com:owner/repo.git o ssh://git@github.com/owner/repo.git.
 */
Map parseGitHubRepository(String gitUrl) {
    String clean = (gitUrl ?: '').toString().trim().replaceAll(/\.git$/, '')
    if (clean.isEmpty()) {
        return buildRepository('', '', false)
    }

    String path = ''
    if (clean.startsWith('git@github.com:')) {
        path = clean.substring('git@github.com:'.length())
    } else if (clean.contains('github.com/')) {
        path = clean.substring(clean.indexOf('github.com/') + 'github.com/'.length())
    } else {
        return buildRepository('', '', false)
    }

    List<String> parts = path.split('/')
    if (parts.size() < 2) {
        return buildRepository('', '', false)
    }
    return buildRepository(parts[0], parts[1], true)
}

private Map buildRepository(String account, String name, boolean resolved) {
    String owner = (account ?: '').toString().trim()
    String repoName = (name ?: '').toString().trim()
    return [
        account : owner,
        name    : repoName,
        fullName: resolved ? "${owner}/${repoName}" : '',
        resolved: resolved && !owner.isEmpty() && !repoName.isEmpty()
    ]
}

return this
