// jenkins/vars/pipelineUtils.groovy
// Historia de Usuario: US-09 (SCRUM-21 / SCRUM-55)
// Propósito: Utilidades transversales reutilizables para el pipeline CI/CD de CircleGuard
// (metadatos de ramas/PRs, construcción de comandos Gradle/Docker, validación de SemVer y resúmenes).

/**
 * Punto de entrada por defecto que devuelve un resumen del contexto de ejecución del pipeline.
 */
Map call(Map config = [:]) {
    String branchName = config.containsKey('branchName') ? (config.branchName ?: '') : (env?.BRANCH_NAME ?: 'local')
    String changeId = config.containsKey('changeId') ? (config.changeId ?: '') : (env?.CHANGE_ID ?: '')
    String changeTarget = config.containsKey('changeTarget') ? (config.changeTarget ?: '') : (env?.CHANGE_TARGET ?: '')

    boolean isPR = !changeId.trim().isEmpty()
    boolean isMain = !isPR && (branchName == 'main')
    boolean canDeployProd = isMain && !isPR

    return [
        branchName   : branchName,
        changeId     : changeId,
        changeTarget : changeTarget,
        isPullRequest: isPR,
        isMainBranch : isMain,
        canDeployProd: canDeployProd
    ]
}

/**
 * Construye el comando Gradle optimizado para compilar, ejecutar pruebas unitarias
 * y generar reportes JaCoCo únicamente sobre los microservicios afectados.
 */
String buildGradleCommandForServices(List<String> services, Map options = [:]) {
    if (!services || services.isEmpty()) {
        return ''
    }

    boolean includeTests = options.containsKey('includeTests') ? (options.includeTests as boolean) : true
    boolean includeJacoco = options.containsKey('includeJacoco') ? (options.includeJacoco as boolean) : true
    boolean daemon = options.containsKey('daemon') ? (options.daemon as boolean) : false

    List<String> tasks = []
    for (String svc : services) {
        String normalized = svc.startsWith(':services:') ? svc : ":services:${svc}"
        tasks.add("${normalized}:assemble".toString())
        if (includeTests) {
            tasks.add("${normalized}:test".toString())
        }
        if (includeJacoco) {
            tasks.add("${normalized}:jacocoTestReport".toString())
        }
    }

    String flags = daemon ? '--stacktrace' : '--no-daemon --stacktrace'
    return "./gradlew ${tasks.join(' ')} ${flags}".trim()
}

/**
 * Valida que una etiqueta de versión cumpla estrictamente SemVer (X.Y.Z o X.Y.Z-rc.N)
 * y rechaza explícitamente el uso del tag mutable 'latest'.
 */
boolean isValidSemVerTag(String versionTag) {
    if (!versionTag) {
        return false
    }
    String clean = versionTag.trim()
    if (clean.equalsIgnoreCase('latest')) {
        return false
    }
    if (clean.startsWith('v')) {
        clean = clean.substring(1)
    }
    return (clean ==~ /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/)
}

/**
 * Construye la referencia completa de imagen Docker inmutable para un componente de CircleGuard.
 * Lanza IllegalArgumentException si se intenta usar 'latest' o una versión inválida.
 */
String formatDockerImageRef(String registryUrl, String componentName, String versionTag, String namespace = 'circleguard') {
    if (!isValidSemVerTag(versionTag)) {
        throw new IllegalArgumentException("Etiqueta de imagen invalida o prohibida ('${versionTag}'). Se exige SemVer estricto y se prohibe ':latest'.")
    }
    String cleanTag = versionTag.trim().startsWith('v') ? versionTag.trim().substring(1) : versionTag.trim()
    String shortName = componentName.replace('circleguard-', '')
    String cleanRegistry = (registryUrl ?: 'localhost:5000').replaceAll('/+$', '')
    return "${cleanRegistry}/${namespace}/${shortName}:${cleanTag}"
}

/**
 * Formatea un resumen legible en texto plano del resultado de detectChangedServices
 * para registrarlo en la consola de Jenkins o en notificaciones.
 */
String formatDetectionSummary(Map detectionResult) {
    List<String> backend = (detectionResult?.backendServices ?: []) as List<String>
    boolean mobile = (detectionResult?.mobileChanged ?: false) as boolean
    boolean shared = (detectionResult?.sharedChanged ?: false) as boolean
    boolean infra = (detectionResult?.infraChanged ?: false) as boolean
    boolean skipCi = (detectionResult?.skipCiBuild ?: false) as boolean

    return [
        "=== CircleGuard Monorepo Change Detection Summary ===",
        "Archivos modificados : ${(detectionResult?.changedFiles ?: []).size()}",
        "Cambio global/shared : ${shared}",
        "Servicios backend    : ${backend.isEmpty() ? 'ninguno' : backend.join(', ')}",
        "Cliente web (mobile) : ${mobile}",
        "Infraestructura      : ${infra}",
        "Omitir build pesado  : ${skipCi}",
        "====================================================="
    ].join('\n')
}

return this
