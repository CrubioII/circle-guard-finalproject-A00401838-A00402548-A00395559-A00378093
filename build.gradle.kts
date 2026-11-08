plugins {
    id("org.springframework.boot") version "3.2.4" apply false
    id("io.spring.dependency-management") version "1.1.4" apply false
    kotlin("jvm") version "1.9.24" apply false
    kotlin("plugin.spring") version "1.9.24" apply false
    kotlin("plugin.jpa") version "1.9.24" apply false
}

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
