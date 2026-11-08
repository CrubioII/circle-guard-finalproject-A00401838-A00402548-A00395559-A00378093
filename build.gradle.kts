import org.gradle.testing.jacoco.plugins.JacocoPluginExtension
import org.gradle.testing.jacoco.tasks.JacocoCoverageVerification
import org.gradle.testing.jacoco.tasks.JacocoReport
import java.math.BigDecimal

plugins {
    id("org.springframework.boot") version "3.2.4" apply false
    id("io.spring.dependency-management") version "1.1.4" apply false
    kotlin("jvm") version "1.9.24" apply false
    kotlin("plugin.spring") version "1.9.24" apply false
    kotlin("plugin.jpa") version "1.9.24" apply false
    jacoco
    id("org.sonarqube") version "5.1.0.4882"
}

val coreBackendServices = setOf(
    "circleguard-auth-service",
    "circleguard-identity-service",
    "circleguard-promotion-service",
    "circleguard-form-service",
    "circleguard-gateway-service"
)

val minimumCoreCoverage = BigDecimal("0.60")

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

    extensions.configure<JavaPluginExtension> {
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(21))
        }
    }

    extensions.configure<JacocoPluginExtension> {
        toolVersion = "0.8.12"
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

    tasks.withType<JacocoReport> {
        dependsOn(tasks.withType<Test>())
        reports {
            xml.required.set(true)
            xml.outputLocation.set(layout.buildDirectory.file("reports/jacoco/test/jacocoTestReport.xml"))
            html.required.set(true)
            html.outputLocation.set(layout.buildDirectory.dir("reports/jacoco/test/html"))
            csv.required.set(false)
        }
    }

    tasks.withType<JacocoCoverageVerification> {
        dependsOn(tasks.withType<JacocoReport>())
        violationRules {
            rule {
                enabled = project.name in coreBackendServices
                limit {
                    counter = "LINE"
                    value = "COVEREDRATIO"
                    minimum = minimumCoreCoverage
                }
            }
        }
    }

    sonar {
        properties {
            property(
                "sonar.coverage.jacoco.xmlReportPaths",
                layout.buildDirectory.file("reports/jacoco/test/jacocoTestReport.xml").get().asFile.absolutePath
            )
            property(
                "sonar.junit.reportPaths",
                layout.buildDirectory.dir("test-results/test").get().asFile.absolutePath
            )
        }
    }
}

sonar {
    properties {
        property("sonar.projectKey", System.getenv("SONAR_PROJECT_KEY") ?: "circleguard-monorepo")
        property("sonar.projectName", "CircleGuard Monorepo")
        property("sonar.host.url", System.getenv("SONAR_HOST_URL") ?: "http://localhost:9000")
        property("sonar.sourceEncoding", "UTF-8")
        property(
            "sonar.coverage.jacoco.xmlReportPaths",
            subprojects.joinToString(",") {
                it.layout.buildDirectory.file("reports/jacoco/test/jacocoTestReport.xml").get().asFile.absolutePath
            }
        )
        property(
            "sonar.coverage.exclusions",
            "**/config/**,**/dto/**,**/model/**,**/entity/**,**/*Application.*"
        )
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

val validateJenkinsSonarQualityGate by tasks.registering {
    group = "verification"
    description = "Valida la integracion de Gradle + JaCoCo + SonarQube Quality Gate en Jenkins (US-10 / SCRUM-22)"
    doLast {
        val scriptFile = file("jenkins/test/validateSonarQualityGate.groovy")
        check(scriptFile.exists()) { "No se encontro el script de validacion: ${scriptFile.path}" }
        System.setProperty("circleguard.repoRoot", projectDir.absolutePath)
        groovy.lang.GroovyShell().evaluate(scriptFile)
    }
}
