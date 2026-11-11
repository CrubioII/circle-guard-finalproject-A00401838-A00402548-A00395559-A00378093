// jenkins/vars/rollbackDeployment.groovy
// Historia de Usuario: US-14 (SCRUM-26) — CA2
// Propósito: Exponer el mecanismo de rollback de infra/scripts/rollback.sh como
// pasos reutilizables de la Shared Library, para que el despliegue (US-13) registre
// la versión desplegada y la estable, y restaure la última versión estable cuando
// el smoke test / healthcheck post-despliegue falla.
//
// Uso típico en la etapa de despliegue:
//   rollbackDeployment.markDeployed(env: 'stage', version: semver)
//   try {
//       sh "... despliegue y smoke test ..."
//       rollbackDeployment.markStable(env: 'stage', version: semver)
//   } catch (err) {
//       rollbackDeployment(env: 'stage', host: env.STAGE_HOST)   // restaura la última estable
//       throw err
//   }
//
// Rollback manual: parámetro ROLLBACK_TARGET_VERSION del Jenkinsfile.

import groovy.transform.Field

@Field final List<String> ALLOWED_ENVS = ['dev', 'stage', 'prod']
@Field final String SCRIPT = 'infra/scripts/rollback.sh'

/**
 * Restaura un ambiente a una versión SemVer.
 *
 * Parámetros:
 * - env (String, obligatorio): dev | stage | prod.
 * - targetVersion (String): versión a restaurar; vacío = última versión estable registrada.
 * - registryUrl (String): registro Docker (por defecto 52.14.6.11:5000).
 * - host (String): IP del nodo del ambiente; redespliega por SSH con deploy/scripts/environment.sh (US-13).
 *   Requiere las credenciales SSH y de Nexus inyectadas con withCredentials, igual que el despliegue.
 * - dryRun (Boolean): muestra los comandos sin ejecutarlos.
 */
Map call(Map config = [:]) {
    String targetEnv = requireEnv(config.env)
    String target = (config.targetVersion ?: '').toString().trim()
    if (target) {
        requireSemVer(target)
    }
    String toArg = target ? " --to '${target}'" : ''
    String hostArg = config.host ? " --host '${config.host}'" : ''
    echo "[rollbackDeployment] Restaurando '${targetEnv}' a ${target ?: 'la última versión estable registrada'}."
    runScript(config, "rollback '${targetEnv}'${toArg}${hostArg}")
    return [env: targetEnv, targetVersion: target ?: 'last_stable_version']
}

/** Registra la versión que se acaba de desplegar (antes del smoke test). */
void markDeployed(Map config = [:]) {
    String targetEnv = requireEnv(config.env)
    String version = requireSemVer(config.version)
    runScript(config, "mark-deployed '${targetEnv}' '${version}'")
}

/** Registra la versión como estable tras pasar el smoke test / healthcheck. */
void markStable(Map config = [:]) {
    String targetEnv = requireEnv(config.env)
    String version = requireSemVer(config.version)
    runScript(config, "mark-stable '${targetEnv}' '${version}'")
}

private void runScript(Map config, String args) {
    List<String> vars = ["REGISTRY_URL=${config.registryUrl ?: '52.14.6.11:5000'}"]
    if (config.dryRun) {
        vars << 'DRY_RUN=1'
    }
    withEnv(vars) {
        sh "chmod +x ${SCRIPT} && ./${SCRIPT} ${args}"
    }
}

private String requireEnv(def value) {
    String targetEnv = (value ?: '').toString().trim()
    if (!ALLOWED_ENVS.contains(targetEnv)) {
        error("[rollbackDeployment] Ambiente inválido '${targetEnv}'. Valores permitidos: ${ALLOWED_ENVS}.")
    }
    return targetEnv
}

private String requireSemVer(def value) {
    String version = (value ?: '').toString().trim()
    if (!(version ==~ /^\d+\.\d+\.\d+(-rc\.\d+)?$/)) {
        error("[rollbackDeployment] Versión '${version}' inválida: se requiere SemVer X.Y.Z y nunca 'latest'.")
    }
    return version
}
