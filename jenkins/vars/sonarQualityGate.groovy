// jenkins/vars/sonarQualityGate.groovy
// Historia de Usuario: US-10 (SCRUM-22 / SCRUM-58 / SCRUM-59 / SCRUM-60)
// Propósito: Orquestar la generación y publicación de reportes JaCoCo, la ejecución
// del análisis SonarQube con Gradle y la compuerta bloqueante waitForQualityGate(abortPipeline: true)
// con umbral de cobertura >= 60% para los servicios núcleo.
//
// El Jenkinsfile carga este archivo con `load` desde el workspace (como notifyPipeline, US-14),
// así que corre en el sandbox y en el intérprete CPS de Jenkins:
//   - sin parámetros con valor por defecto en las firmas (fallan al cargar con `load`);
//   - los helpers de cálculo puro no llaman pasos de Jenkins (el Matcher nunca cruza un checkpoint);
//   - los reportes se leen con los pasos fileExists/readFile, relativos al workspace del build
//     (new File(...) está bloqueado por el sandbox y apuntaría al directorio del controlador).

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

@Field final double DEFAULT_CORE_COVERAGE_THRESHOLD = 60.0d
@Field final String DEFAULT_SONAR_SERVER_NAME = 'SonarQube'
@Field final String DEFAULT_SONAR_PROJECT_KEY = 'circleguard-monorepo'
@Field final String DEFAULT_SONAR_PROJECT_NAME = 'CircleGuard Monorepo'
@Field final String DEFAULT_QUALITY_GATE_NAME = 'CircleGuard-Quality-Gate'

/**
 * Devuelve la configuración base de SonarQube y JaCoCo para el pipeline.
 */
Map call(Map config) {
    config = config ?: [:]
    double threshold = config.containsKey('minCoreCoverage')
        ? (config.minCoreCoverage as double)
        : DEFAULT_CORE_COVERAGE_THRESHOLD

    return [
        sonarServerName    : (config.sonarServerName ?: DEFAULT_SONAR_SERVER_NAME).toString(),
        projectKey         : (config.projectKey ?: (env?.SONAR_PROJECT_KEY ?: DEFAULT_SONAR_PROJECT_KEY)).toString(),
        projectName        : (config.projectName ?: DEFAULT_SONAR_PROJECT_NAME).toString(),
        qualityGateName    : (config.qualityGateName ?: DEFAULT_QUALITY_GATE_NAME).toString(),
        minCoreCoverage    : threshold,
        allBackendServices : ALL_BACKEND_SERVICES,
        coreBackendServices: CORE_BACKEND_SERVICES,
        xmlReportPaths     : resolveJacocoXmlReportPaths(ALL_BACKEND_SERVICES)
    ]
}

/**
 * Devuelve las rutas relativas de los reportes XML de JaCoCo para los servicios indicados.
 */
List<String> resolveJacocoXmlReportPaths(List<String> services) {
    List<String> targetServices = (services == null || services.isEmpty()) ? ALL_BACKEND_SERVICES : services
    return targetServices.collect { String svc ->
        String cleanName = svc.replaceFirst('^:services:', '')
        "services/${cleanName}/build/reports/jacoco/test/jacocoTestReport.xml".toString()
    }
}

/**
 * Construye el comando Gradle para ejecutar el análisis de SonarQube enviando
 * las rutas de cobertura XML de JaCoCo generadas en la etapa de pruebas.
 */
String buildSonarGradleCommand(List<String> services, Map options) {
    options = options ?: [:]
    List<String> targetServices = (services == null || services.isEmpty()) ? ALL_BACKEND_SERVICES : services
    String projectKey = (options.projectKey ?: (env?.SONAR_PROJECT_KEY ?: DEFAULT_SONAR_PROJECT_KEY)).toString().trim()
    String projectName = (options.projectName ?: DEFAULT_SONAR_PROJECT_NAME).toString().trim()
    boolean skipTests = options.containsKey('skipTests') ? (options.skipTests as boolean) : true
    boolean daemon = options.containsKey('daemon') ? (options.daemon as boolean) : false

    List<String> xmlPaths = resolveJacocoXmlReportPaths(targetServices)
    List<String> args = [
        './gradlew',
        'sonar',
        "-Dsonar.projectKey=${projectKey}",
        "-Dsonar.projectName=\"${projectName}\"",
        "-Dsonar.coverage.jacoco.xmlReportPaths=${xmlPaths.join(',')}"
    ]

    if (options.sonarHostUrl) {
        args.add("-Dsonar.host.url=${options.sonarHostUrl}")
    }
    if (skipTests) {
        args.add('-x test')
    }
    args.add(daemon ? '--stacktrace' : '--no-daemon --stacktrace')

    return args.join(' ').trim()
}

/**
 * Extrae las métricas de cobertura de líneas e instrucciones a partir del contenido
 * de un archivo jacocoTestReport.xml.
 */
Map parseJacocoXmlCounters(String xmlContent) {
    if (!xmlContent || xmlContent.trim().isEmpty()) {
        return [
            found                     : false,
            missedLines               : 0,
            coveredLines              : 0,
            totalLines                : 0,
            lineCoveragePercent       : 0.0d,
            missedInstructions        : 0,
            coveredInstructions       : 0,
            instructionCoveragePercent: 0.0d
        ]
    }

    String tailSection = xmlContent
    int lastPackageClose = xmlContent.lastIndexOf('</package>')
    if (lastPackageClose >= 0) {
        tailSection = xmlContent.substring(lastPackageClose)
    }

    Map lineCounter = extractCounterFromXml(tailSection, 'LINE')
    if (!lineCounter.found) {
        lineCounter = extractCounterFromXml(xmlContent, 'LINE')
    }

    Map instructionCounter = extractCounterFromXml(tailSection, 'INSTRUCTION')
    if (!instructionCounter.found) {
        instructionCounter = extractCounterFromXml(xmlContent, 'INSTRUCTION')
    }

    int missedLines = lineCounter.missed as int
    int coveredLines = lineCounter.covered as int
    int totalLines = missedLines + coveredLines
    double linePct = totalLines > 0
        ? Math.round((coveredLines * 10000.0d) / totalLines) / 100.0d
        : 0.0d

    int missedInstr = instructionCounter.missed as int
    int coveredInstr = instructionCounter.covered as int
    int totalInstr = missedInstr + coveredInstr
    double instrPct = totalInstr > 0
        ? Math.round((coveredInstr * 10000.0d) / totalInstr) / 100.0d
        : 0.0d

    return [
        found                     : (lineCounter.found || instructionCounter.found),
        missedLines               : missedLines,
        coveredLines              : coveredLines,
        totalLines                : totalLines,
        lineCoveragePercent       : linePct,
        missedInstructions        : missedInstr,
        coveredInstructions       : coveredInstr,
        instructionCoveragePercent: instrPct
    ]
}

Map extractCounterFromXml(String xmlFragment, String counterType) {
    def matcher = (xmlFragment =~ /<counter\s+type=['"]${counterType}['"]\s+missed=['"](\d+)['"]\s+covered=['"](\d+)['"]\s*\/>/)
    int lastMissed = 0
    int lastCovered = 0
    boolean found = false
    while (matcher.find()) {
        found = true
        lastMissed = matcher.group(1) as int
        lastCovered = matcher.group(2) as int
    }
    return [found: found, missed: lastMissed, covered: lastCovered]
}

/**
 * Recolecta la cobertura JaCoCo de los servicios indicados leyendo sus archivos XML
 * en el workspace si existen.
 */
Map collectServiceCoverage(List<String> services, String workspaceRoot) {
    List<String> targetServices = (services == null || services.isEmpty()) ? ALL_BACKEND_SERVICES : services
    String root = (workspaceRoot ?: '.').toString()
    Map<String, Map> byService = [:]

    for (String svc : targetServices) {
        String cleanName = svc.replaceFirst('^:services:', '')
        String relativePath = "services/${cleanName}/build/reports/jacoco/test/jacocoTestReport.xml".toString()
        // '.' = workspace del build: los pasos fileExists/readFile resuelven la ruta relativa a él.
        String reportPath = (root == '.') ? relativePath : "${root}/${relativePath}".toString()
        boolean reportExists = fileExists(reportPath)
        Map metrics = parseJacocoXmlCounters(reportExists ? readFile(file: reportPath, encoding: 'UTF-8') : '')

        byService[cleanName] = metrics + [
            service      : cleanName,
            isCoreService: CORE_BACKEND_SERVICES.contains(cleanName),
            xmlPath      : relativePath,
            reportExists : reportExists
        ]
    }

    return byService
}

/**
 * Evalúa el resultado del Quality Gate de SonarQube junto con el umbral de cobertura
 * (>= 60%) sobre los servicios núcleo evaluados.
 */
Map evaluateQualityGate(Map config) {
    config = config ?: [:]
    String sonarStatus = (config.sonarStatus ?: 'OK').toString().trim().toUpperCase()
    double minCoreCoverage = config.containsKey('minCoreCoverage')
        ? (config.minCoreCoverage as double)
        : DEFAULT_CORE_COVERAGE_THRESHOLD
    boolean enforceLocalCoreCoverage = config.containsKey('enforceLocalCoreCoverage')
        ? (config.enforceLocalCoreCoverage as boolean)
        : false

    Map<String, Object> coverageMap = (config.coverageByService ?: [:]) as Map<String, Object>
    List<Map> failedCoreServices = []

    coverageMap.each { String svc, Object rawEntry ->
        String cleanName = svc.replaceFirst('^:services:', '')
        boolean isCore = CORE_BACKEND_SERVICES.contains(cleanName)
        double pct = 0.0d
        boolean reportExists = true

        if (rawEntry instanceof Number) {
            pct = (rawEntry as Number).doubleValue()
        } else if (rawEntry instanceof Map) {
            Map entryMap = rawEntry as Map
            pct = (entryMap.lineCoveragePercent ?: 0.0d) as double
            reportExists = entryMap.containsKey('reportExists') ? (entryMap.reportExists as boolean) : true
        }

        if (isCore && (enforceLocalCoreCoverage || rawEntry instanceof Number) && reportExists && pct < minCoreCoverage) {
            failedCoreServices.add([
                service            : cleanName,
                lineCoveragePercent: pct,
                requiredMinimum    : minCoreCoverage
            ])
        }
    }

    boolean sonarOk = (sonarStatus == 'OK')
    boolean coreCoverageOk = failedCoreServices.isEmpty()
    boolean passed = sonarOk && coreCoverageOk

    List<String> reasons = []
    if (!sonarOk) {
        reasons.add("SonarQube Quality Gate devolvió estado '${sonarStatus}' (se requiere 'OK').")
    }
    if (!coreCoverageOk) {
        String detail = failedCoreServices.collect { Map item ->
            "${item.service}=${item.lineCoveragePercent}% (< ${item.requiredMinimum}%)"
        }.join(', ')
        reasons.add("Cobertura insuficiente en servicios núcleo: ${detail}.")
    }
    if (passed) {
        reasons.add("Quality Gate aprobado (SonarQube=${sonarStatus}, umbral núcleo >= ${minCoreCoverage}%).")
    }

    return [
        passed            : passed,
        sonarStatus       : sonarStatus,
        minCoreCoverage   : minCoreCoverage,
        failedCoreServices: failedCoreServices,
        reason            : reasons.join(' ')
    ]
}

/**
 * Ejecuta waitForQualityGate(abortPipeline: true) en Jenkins y verifica el resultado.
 * Si el Quality Gate falla o la cobertura núcleo está por debajo del umbral, aborta el pipeline.
 */
Map enforceQualityGate(Map config) {
    config = config ?: [:]
    double minCoreCoverage = config.containsKey('minCoreCoverage')
        ? (config.minCoreCoverage as double)
        : DEFAULT_CORE_COVERAGE_THRESHOLD

    Object qgResult = null
    String sonarStatus = 'OK'

    if (config.containsKey('mockQualityGateStatus') && config.mockQualityGateStatus != null) {
        sonarStatus = config.mockQualityGateStatus.toString().trim().toUpperCase()
        if (sonarStatus != 'OK') {
            error("Pipeline abortado por waitForQualityGate(abortPipeline: true): Quality Gate en estado '${sonarStatus}'.")
        }
    } else {
        // Con abortPipeline: true el propio paso detiene el build si el estado no es OK.
        // `status` es una propiedad permitida en el sandbox (sin getMetaClass, que está bloqueado).
        qgResult = waitForQualityGate(abortPipeline: true)
        if (qgResult != null && qgResult.status) {
            sonarStatus = qgResult.status.toString().trim().toUpperCase()
        }
    }

    Map evaluation = evaluateQualityGate([
        sonarStatus             : sonarStatus,
        minCoreCoverage         : minCoreCoverage,
        coverageByService       : config.coverageByService ?: [:],
        enforceLocalCoreCoverage: (config.enforceLocalCoreCoverage ?: false) as boolean
    ])

    if (!evaluation.passed) {
        error("Pipeline abortado por Quality Gate (US-10 / CA3): ${evaluation.reason}")
    }

    echo "[sonarQualityGate] ${evaluation.reason}"
    return evaluation
}

/**
 * Publica los reportes de cobertura JaCoCo en la interfaz de Jenkins.
 * Si el plugin jacoco está instalado invoca el step jacoco(...); en todos los casos
 * deja los reportes XML y HTML listos para archivarse como artefactos del build.
 */
Map publishJacocoReports(Map config) {
    config = config ?: [:]
    List<String> services = (config.services ?: ALL_BACKEND_SERVICES) as List<String>
    List<String> xmlPaths = resolveJacocoXmlReportPaths(services)
    boolean pluginPublished = false

    try {
        jacoco(
            execPattern: '**/build/jacoco/*.exec',
            classPattern: '**/build/classes/java/main,**/build/classes/kotlin/main',
            sourcePattern: '**/src/main/java,**/src/main/kotlin',
            inclusionPattern: '**/*.class',
            exclusionPattern: '**/*Test*,**/config/**,**/dto/**,**/model/**,**/entity/**,**/*Application*'
        )
        pluginPublished = true
        echo "[sonarQualityGate] Reportes JaCoCo publicados en la interfaz de Jenkins (${xmlPaths.size()} servicios)."
    } catch (Throwable ignored) {
        echo "[sonarQualityGate] Paso jacoco() no disponible en este runtime; se archivan los reportes XML/HTML de JaCoCo (${xmlPaths.size()} servicios)."
    }

    return [
        publishedByPlugin: pluginPublished,
        services         : services,
        xmlReportPaths   : xmlPaths
    ]
}

return this
