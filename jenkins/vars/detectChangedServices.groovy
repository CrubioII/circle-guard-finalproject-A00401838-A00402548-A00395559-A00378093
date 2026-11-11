// jenkins/vars/detectChangedServices.groovy
// Historia de Usuario: US-09 (SCRUM-21 / SCRUM-55)
// Propósito: Detectar de manera determinística qué microservicios backend, cliente web
// o componentes compartidos fueron modificados en un Pull Request o commit.

import groovy.transform.Field

@Field final List<String> ALL_BACKEND_SERVICES = [
    'circleguard-auth-service',
    'circleguard-identity-service',
    'circleguard-promotion-service',
    'circleguard-notification-service',
    'circleguard-form-service',
    'circleguard-file-service',
    'circleguard-gateway-service',
    'circleguard-dashboard-service'
]

@Field final List<String> CORE_BACKEND_SERVICES = [
    'circleguard-auth-service',
    'circleguard-identity-service',
    'circleguard-promotion-service',
    'circleguard-form-service',
    'circleguard-gateway-service'
]

@Field final Map<String, Integer> SERVICE_PORTS = [
    'circleguard-auth-service'        : 8180,
    'circleguard-identity-service'    : 8083,
    'circleguard-promotion-service'   : 8082,
    'circleguard-notification-service': 8086,
    'circleguard-form-service'        : 8085,
    'circleguard-file-service'        : 8087,
    'circleguard-gateway-service'     : 8084,
    'circleguard-dashboard-service'   : 8088
]

@Field final List<String> GLOBAL_BUILD_PATHS = [
    'build.gradle.kts',
    'settings.gradle.kts',
    'gradle.properties',
    'gradlew',
    'gradle/',
    'libs/',
    'Jenkinsfile',
    'jenkins/'
]

@Field final List<String> INFRA_PATHS = [
    'docker-compose',
    'deploy/',
    'infra/',
    'init-db.sql'
]

/**
 * Punto de entrada principal cuando se invoca detectChangedServices(config) desde un Jenkinsfile.
 *
 * Parámetros soportados en config (Map):
 * - forceAll (Boolean): Si es true, marca todos los 8 microservicios y mobile como afectados.
 * - baseBranch (String): Rama base de comparación para PRs (por defecto env.CHANGE_TARGET o 'main').
 * - changedFilesOverride (List<String>): Lista explícita de rutas cambiadas (útil para pruebas reproducibles sin depender de git).
 */
Map call(Map config = [:]) {
    boolean forceAll = (config.forceAll ?: false) as boolean
    String baseBranch = config.baseBranch ?: (env?.CHANGE_TARGET ?: 'main')

    List<String> changedFiles = []
    if (config.containsKey('changedFilesOverride') && config.changedFilesOverride != null) {
        changedFiles = (config.changedFilesOverride as List<String>).collect { it.toString().trim() }.findAll { it }
    } else {
        changedFiles = resolveChangedFilesFromGit(baseBranch)
    }

    return analyzeChangedFiles(changedFiles, forceAll)
}

/**
 * Analiza una lista de archivos modificados (rutas relativas a la raíz del repositorio)
 * y devuelve un mapa estructurado con los servicios afectados, banderas de impacto y tareas de Gradle.
 */
Map analyzeChangedFiles(List<String> rawFiles, boolean forceAll = false) {
    List<String> changedFiles = (rawFiles ?: [])
        .collect { it.replace('\\', '/').trim() }
        .findAll { !it.isEmpty() }
        .unique()

    Set<String> backendServices = new LinkedHashSet<String>()
    boolean mobileChanged = false
    boolean sharedChanged = false
    boolean infraChanged = false
    boolean docsOnly = !changedFiles.isEmpty()

    if (forceAll) {
        backendServices.addAll(ALL_BACKEND_SERVICES)
        mobileChanged = true
        sharedChanged = true
        docsOnly = false
    }

    for (String file : changedFiles) {
        boolean isDocFile = isDocumentationOrGovernanceFile(file)
        if (!isDocFile) {
            docsOnly = false
        }

        // 1. Verificar si es un cambio global/compartido que afecta a todos los microservicios
        if (matchesGlobalBuildPath(file)) {
            sharedChanged = true
            backendServices.addAll(ALL_BACKEND_SERVICES)
            continue
        }

        // 2. Verificar si afecta infraestructura / despliegue
        if (matchesInfraPath(file)) {
            infraChanged = true
        }

        // 3. Verificar si afecta un microservicio backend específico en services/<nombre>/
        if (file.startsWith('services/')) {
            String[] parts = file.split('/')
            if (parts.length >= 2) {
                String candidateService = parts[1]
                if (ALL_BACKEND_SERVICES.contains(candidateService)) {
                    backendServices.add(candidateService)
                }
            }
            continue
        }

        // 4. Verificar si afecta al cliente web/móvil Expo en mobile/ o a sus pruebas E2E en e2e/ (US-34)
        if (file.startsWith('mobile/') || file.startsWith('e2e/')) {
            mobileChanged = true
            continue
        }
    }

    // Ordenar los servicios detectados respetando el orden canónico de ALL_BACKEND_SERVICES
    List<String> orderedBackend = ALL_BACKEND_SERVICES.findAll { backendServices.contains(it) }
    List<String> affectedCore = CORE_BACKEND_SERVICES.findAll { backendServices.contains(it) }

    List<String> allComponents = []
    allComponents.addAll(orderedBackend)
    if (mobileChanged) {
        allComponents.add('mobile')
    }

    List<String> gradleProjects = orderedBackend.collect { ":services:${it}".toString() }
    List<String> gradleTestTasks = orderedBackend.collect { ":services:${it}:test".toString() }
    List<String> gradleJacocoTasks = orderedBackend.collect { ":services:${it}:jacocoTestReport".toString() }

    boolean fullBuild = forceAll || sharedChanged || (orderedBackend.size() == ALL_BACKEND_SERVICES.size())
    boolean skipCiBuild = !forceAll && changedFiles.size() > 0 && docsOnly && orderedBackend.isEmpty() && !mobileChanged && !infraChanged

    return [
        changedFiles      : changedFiles,
        backendServices   : orderedBackend,
        coreServices      : affectedCore,
        mobileChanged     : mobileChanged,
        sharedChanged     : sharedChanged,
        infraChanged      : infraChanged,
        docsOnly          : docsOnly,
        fullBuild         : fullBuild,
        skipCiBuild       : skipCiBuild,
        allComponents     : allComponents,
        gradleProjects    : gradleProjects,
        gradleTestTasks   : gradleTestTasks,
        gradleJacocoTasks : gradleJacocoTasks,
        servicePorts      : SERVICE_PORTS.subMap(orderedBackend)
    ]
}

/**
 * Obtiene la lista de archivos modificados desde Git evaluando si la ejecución
 * corresponde a un Pull Request (CHANGE_TARGET) o a un commit directo/merge en rama.
 */
List<String> resolveChangedFilesFromGit(String baseBranch = 'main') {
    String diffOutput = ''
    try {
        if (env?.CHANGE_TARGET) {
            String target = env.CHANGE_TARGET
            diffOutput = sh(
                script: "git diff --name-only origin/${target}...HEAD 2>/dev/null || git diff --name-only ${target}...HEAD 2>/dev/null || git diff --name-only HEAD~1..HEAD",
                returnStdout: true
            ).trim()
        } else {
            diffOutput = sh(
                script: "git diff --name-only HEAD~1..HEAD 2>/dev/null || git show --pretty='' --name-only HEAD",
                returnStdout: true
            ).trim()
        }
    } catch (Exception e) {
        echo "[detectChangedServices] Advertencia: No se pudo calcular git diff exacto (${e.message}). Activando fallback a todos los servicios."
        return ['build.gradle.kts']
    }

    if (!diffOutput) {
        return []
    }
    return diffOutput.readLines().collect { it.trim() }.findAll { !it.isEmpty() }
}

boolean matchesGlobalBuildPath(String file) {
    return GLOBAL_BUILD_PATHS.any { String prefix ->
        file == prefix || file.startsWith(prefix)
    }
}

boolean matchesInfraPath(String file) {
    return INFRA_PATHS.any { String prefix ->
        file == prefix || file.startsWith(prefix)
    }
}

boolean isDocumentationOrGovernanceFile(String file) {
    return file.startsWith('docs/') ||
           file.startsWith('.github/') ||
           file.endsWith('.md') ||
           file.endsWith('.tex') ||
           file.endsWith('.pdf') ||
           file.endsWith('.excalidraw') ||
           file.endsWith('.svg') ||
           file.endsWith('.png')
}

return this
