plugins {
    id("org.springframework.boot") version "3.2.4" apply false
    id("io.spring.dependency-management") version "1.1.4" apply false
    kotlin("jvm") version "1.9.24" apply false
    kotlin("plugin.spring") version "1.9.24" apply false
    kotlin("plugin.jpa") version "1.9.24" apply false
}

// US-31 / US-32: servicios con umbral mínimo de cobertura de líneas (JaCoCo).
// Notification, file y dashboard (US-32) publican reportes pero no tienen umbral obligatorio.
val coreCoverageServices = setOf(
    "circleguard-auth-service",
    "circleguard-identity-service",
    "circleguard-promotion-service",
    "circleguard-form-service",
    "circleguard-gateway-service"
)
val minimumCoreLineCoverage = java.math.BigDecimal("0.60")

allprojects {
    group = "com.circleguard"
    version = "1.0.0-SNAPSHOT"

    repositories {
        mavenCentral()
    }
}

subprojects {
    apply(plugin = "java")
    apply(plugin = "org.jetbrains.kotlin.jvm")
    apply(plugin = "jacoco")

    extensions.configure<JacocoPluginExtension> {
        toolVersion = "0.8.12"
    }

    extensions.configure<JavaPluginExtension> {
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(21))
        }
    }

    dependencies {
        "implementation"(platform("org.springframework.boot:spring-boot-dependencies:3.2.4"))
        "testImplementation"(platform("org.springframework.boot:spring-boot-dependencies:3.2.4"))
        "compileOnly"("org.projectlombok:lombok")
        "annotationProcessor"("org.projectlombok:lombok")
        "testCompileOnly"("org.projectlombok:lombok")
        "testAnnotationProcessor"("org.projectlombok:lombok")
        "implementation"("org.jetbrains.kotlin:kotlin-reflect")
        "testImplementation"("org.springframework.boot:spring-boot-starter-test")
        "testRuntimeOnly"("com.h2database:h2")
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        kotlinOptions {
            freeCompilerArgs = listOf("-Xjsr305=strict")
            jvmTarget = "21"
        }
    }

    tasks.withType<Test> {
        useJUnitPlatform()
        finalizedBy(tasks.named("jacocoTestReport"))
    }

    tasks.named<JacocoReport>("jacocoTestReport") {
        dependsOn(tasks.named("test"))
        reports {
            xml.required.set(true)
            html.required.set(true)
            csv.required.set(false)
        }
    }

    tasks.named<JacocoCoverageVerification>("jacocoTestCoverageVerification") {
        dependsOn(tasks.named("jacocoTestReport"))
        violationRules {
            rule {
                isEnabled = project.name in coreCoverageServices
                limit {
                    counter = "LINE"
                    value = "COVEREDRATIO"
                    minimum = minimumCoreLineCoverage
                }
            }
        }
    }
}

val validateJenkinsSharedLibrary by tasks.registering {
    group = "verification"
    description = "Ejecuta la validacion reproducible de la Shared Library de Jenkins (US-09 / SCRUM-21)"
    doLast {
        val scriptFile = file("jenkins/test/validateSharedLibrary.groovy")
        check(scriptFile.exists()) { "No se encontro el script de validacion: ${scriptFile.path}" }
        System.setProperty("circleguard.repoRoot", projectDir.absolutePath)
        groovy.lang.GroovyShell().evaluate(scriptFile)
    }
}

val validateJenkinsMultibranchPipeline by tasks.registering {
    group = "verification"
    description = "Valida el Jenkinsfile Multibranch, el job JCasC y el webhook de GitHub (US-30 / SCRUM-113)"
    doLast {
        val scriptFile = file("jenkins/test/validateMultibranchPipeline.groovy")
        check(scriptFile.exists()) { "No se encontro el script de validacion: ${scriptFile.path}" }
        System.setProperty("circleguard.repoRoot", projectDir.absolutePath)
        groovy.lang.GroovyShell().evaluate(scriptFile)
    }
}

val validateJenkinsNotifications by tasks.registering {
    group = "verification"
    description = "Valida el paso notifyPipeline (notificaciones del pipeline en Discord) sin Jenkins ni red (US-14 / SCRUM-70)"
    doLast {
        val scriptFile = file("jenkins/test/validateNotifyPipeline.groovy")
        check(scriptFile.exists()) { "No se encontro el script de validacion: ${scriptFile.path}" }
        System.setProperty("circleguard.repoRoot", projectDir.absolutePath)
        groovy.lang.GroovyShell().evaluate(scriptFile)
    }
}

val validateComposeEnvironments by tasks.registering(Exec::class) {
    group = "verification"
    description = "Valida deploy/compose/docker-compose.{dev,stage,prod}.yml: pila completa, SemVer sin latest y healthchecks con service_healthy (US-08)"
    workingDir = projectDir
    // En Windows 'bash' suele resolver al lanzador de WSL; se prefiere Git Bash si existe (o $BASH_EXE).
    val isWindows = System.getProperty("os.name").lowercase().contains("windows")
    val bashExe = System.getenv("BASH_EXE")
        ?: listOf("C:/Program Files/Git/bin/bash.exe", "C:/Program Files (x86)/Git/bin/bash.exe")
            .firstOrNull { isWindows && file(it).exists() }
        ?: "bash"
    commandLine(bashExe, "deploy/compose/validate-compose.sh")
}

val validateJenkinsSecurity by tasks.registering(Exec::class) {
    group = "verification"
    description = "Valida la seguridad de Jenkins: cuentas, matriz de permisos, aprobadores de prod y secretos (US-31)"
    workingDir = projectDir
    val isWindows = System.getProperty("os.name").lowercase().contains("windows")
    val bashExe = System.getenv("BASH_EXE")
        ?: listOf("C:/Program Files/Git/bin/bash.exe", "C:/Program Files (x86)/Git/bin/bash.exe")
            .firstOrNull { isWindows && file(it).exists() }
        ?: "bash"
    commandLine(bashExe, "jenkins/test/validateJenkinsSecurity.sh")
}
