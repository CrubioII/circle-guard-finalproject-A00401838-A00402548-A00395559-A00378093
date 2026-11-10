// jenkins/test/validateNotifyPipeline.groovy
// Historia de Usuario: US-14 (SCRUM-26) — CA1 / Subtarea SCRUM-70
// Propósito: Validación reproducible del paso notifyPipeline sin Jenkins ni Discord:
// simula env, sh, withCredentials, writeFile y archiveArtifacts, y comprueba el
// contenido del mensaje, la política de notificación y que un error al enviar nunca
// rompa el build ni filtre la URL del webhook.
//
// Ejecución: bash jenkins/test/run-notify-validation.sh
//        o:  ./gradlew validateJenkinsNotifications

import groovy.json.JsonOutput
import groovy.json.JsonSlurper

File repoRoot = new File(System.getProperty('circleguard.repoRoot') ?: '.').canonicalFile
File scriptFile = new File(repoRoot, 'jenkins/vars/notifyPipeline.groovy')
assert scriptFile.exists() : "No existe ${scriptFile.path}"

final String FAKE_WEBHOOK = 'https://discord.example/api/webhooks/123/token-de-prueba'

// Estado compartido de los mocks; cada caso lo reinicia con reset().
Map state = [:]
Closure reset = { Map overrides = [:] ->
    state.clear()
    state.putAll([
        env          : [
            BRANCH_NAME : 'main',
            BUILD_URL   : 'http://52.14.6.11:8080/job/circleguard-monorepo/job/main/42/',
            BUILD_NUMBER: '42',
            JOB_NAME    : 'circleguard-monorepo/main'
        ],
        echoes       : [],
        shCalls      : [],
        written      : [:],
        archived     : [],
        credentialIds: [],
        httpCode     : '204',
        credentialMissing: false,
        gitOutput    : "0123456789abcdef0123456789abcdef01234567\nJuan Esteban Cuéllar\nfeat(ci): notify pipeline results in Discord for US-14"
    ])
    state.putAll(overrides)
}

Closure loadStep = {
    Binding binding = new Binding()
    binding.setVariable('env', state.env)
    binding.setVariable('currentBuild', [currentResult: 'SUCCESS', duration: 125000L, previousBuild: [result: 'SUCCESS']])
    binding.setVariable('echo', { String msg -> state.echoes << msg; println("[JENKINS-ECHO] ${msg}") })
    binding.setVariable('sh', { def args ->
        String script = args instanceof Map ? args.script : args.toString()
        state.shCalls << script
        if (script.contains('git log')) {
            return state.gitOutput
        }
        if (script.contains('curl')) {
            // El secreto debe llegar al shell como variable, nunca interpolado en el comando.
            assert !script.contains(FAKE_WEBHOOK) : 'La URL del webhook quedó interpolada en el comando sh'
            assert script.contains('"$DISCORD_WEBHOOK_URL"')
            return state.httpCode
        }
        return ''
    })
    binding.setVariable('writeFile', { Map args -> state.written[args.file] = args.text })
    binding.setVariable('archiveArtifacts', { Map args -> state.archived << args.artifacts })
    binding.setVariable('string', { Map args -> args })
    binding.setVariable('withCredentials', { List bindings, Closure body ->
        bindings.each { state.credentialIds << it.credentialsId }
        if (state.credentialMissing) {
            throw new IllegalStateException("Could not find credentials entry with ID '${bindings[0].credentialsId}'")
        }
        state.env.DISCORD_WEBHOOK_URL = FAKE_WEBHOOK
        try {
            return body.call()
        } finally {
            state.env.remove('DISCORD_WEBHOOK_URL')
        }
    })
    return new GroovyShell(binding).parse(scriptFile)
}

Map mainFlow = [branchName: 'main', isPullRequest: false, isMainBranch: true]
Map prFlow = [branchName: 'PR-25', isPullRequest: true, isMainBranch: false, changeId: '25']

println('=== Validación reproducible de notifyPipeline (US-14 / SCRUM-70) ===')

// -----------------------------------------------------------------------------
// Caso 1: fallo en main -> mensaje con rama, commit, autor, versión, etapa y log (CA1).
// -----------------------------------------------------------------------------
reset()
def step = loadStep()
Map result = step.call(status: 'FAILURE', flow: mainFlow, version: '1.4.0', failedStage: 'Verify stage health', previousStatus: 'SUCCESS')
assert result.notify == true && result.sent == true && result.httpCode == '204'
Map embed = result.payload.embeds[0]
Map fields = embed.fields.collectEntries { [(it.name): it.value] }
assert embed.title.contains('FALLÓ') && embed.title.contains('#42')
assert embed.url == 'http://52.14.6.11:8080/job/circleguard-monorepo/job/main/42/console'
assert fields['Rama'] == '`main`'
assert fields['Versión'] == '`1.4.0`'
assert fields['Commit'] == '`0123456` feat(ci): notify pipeline results in Discord for US-14'
assert fields['Autor'] == 'Juan Esteban Cuéllar'
assert fields['Etapa fallida'] == '`Verify stage health`'
assert fields['Log'].contains('/42/console')
assert fields['Duración'] == '2 min 5 s'
assert result.payload.allowed_mentions == [parse: []] : 'El mensaje no debe mencionar a @everyone/@here'
assert state.credentialIds == ['discord-webhook']
assert state.archived == ['reports/ci/discord-notification.json']
Map sentJson = new JsonSlurper().parseText(state.written['reports/ci/discord-notification.json'])
assert sentJson.embeds[0].fields.size() == embed.fields.size() : 'El JSON enviado debe ser el payload calculado'
assert !JsonOutput.toJson(sentJson).contains(FAKE_WEBHOOK)
assert state.echoes.every { !it.contains(FAKE_WEBHOOK) } : 'La URL del webhook apareció en el log'
println('[OK] Caso 1: fallo en main con todos los datos y envío por la credencial discord-webhook.')

// -----------------------------------------------------------------------------
// Caso 2: fallo en un PR -> enlace al PR, rama destino y autor del PR de GitHub.
// -----------------------------------------------------------------------------
reset(env: [BRANCH_NAME: 'PR-25', CHANGE_ID: '25', CHANGE_TARGET: 'main', CHANGE_BRANCH: 'feature/US-14-pipeline-notifications',
            CHANGE_URL: 'https://github.com/CrubioII/repo/pull/25', CHANGE_AUTHOR: 'Cuellarc',
            BUILD_URL: 'http://jenkins/job/x/PR-25/3/', BUILD_NUMBER: '3', JOB_NAME: 'circleguard-monorepo/PR-25'])
step = loadStep()
result = step.call(status: 'FAILURE', flow: prFlow, version: '', failedStage: 'E2E Playwright', previousStatus: 'SUCCESS')
fields = result.payload.embeds[0].fields.collectEntries { [(it.name): it.value] }
assert result.notify && result.sent
assert fields['Rama'] == '`PR-25`'
assert fields['Pull Request'] == '[#25](https://github.com/CrubioII/repo/pull/25) → `main`'
assert fields['Autor'] == 'Cuellarc'
assert fields['Versión'].startsWith('sin versión')
assert fields['Etapa fallida'] == '`E2E Playwright`'
println('[OK] Caso 2: fallo en PR con enlace al Pull Request y versión ausente explicada.')

// -----------------------------------------------------------------------------
// Caso 3: política -> éxito en PR no notifica; éxito en main, recuperación y abortos sí.
// -----------------------------------------------------------------------------
reset()
step = loadStep()
assert step.shouldNotify('SUCCESS', false, 'SUCCESS').notify == false
assert step.shouldNotify('SUCCESS', true, 'SUCCESS').notify == true
assert step.shouldNotify('SUCCESS', false, 'FAILURE').notify == true
assert step.shouldNotify('ABORTED', false, 'SUCCESS').notify == true
assert step.shouldNotify('UNSTABLE', false, null).notify == true
assert step.shouldNotify('SUCCESS', false, 'SUCCESS', true).notify == true
result = step.call(status: 'SUCCESS', flow: prFlow, previousStatus: 'SUCCESS')
assert result.notify == false && result.sent == false
assert state.shCalls.every { !it.contains('curl') } : 'No debe llamar a Discord si la política dice que no'
println('[OK] Caso 3: política de notificación sin ruido en PRs exitosos.')

// -----------------------------------------------------------------------------
// Caso 4: recuperación -> título RECUPERADO y sin campo "Etapa fallida".
// -----------------------------------------------------------------------------
reset()
step = loadStep()
result = step.call(status: 'SUCCESS', flow: mainFlow, version: '1.4.1', previousStatus: 'FAILURE')
embed = result.payload.embeds[0]
assert result.notify && embed.title.contains('RECUPERADO')
assert !embed.fields*.name.contains('Etapa fallida')
assert embed.color == 3066993
println('[OK] Caso 4: build recuperado tras un fallo.')

// -----------------------------------------------------------------------------
// Caso 5: credencial ausente o Discord caído -> advertencia, el build no falla.
// -----------------------------------------------------------------------------
reset(credentialMissing: true)
step = loadStep()
result = step.call(status: 'FAILURE', flow: mainFlow, version: '1.4.0', failedStage: 'Deploy to dev')
assert result.sent == false && result.error.contains('discord-webhook')
assert state.echoes.any { it.contains('Advertencia') }
reset(httpCode: '404')
step = loadStep()
result = step.call(status: 'FAILURE', flow: mainFlow, version: '1.4.0', failedStage: 'Deploy to dev')
assert result.sent == false && result.httpCode == '404'
println('[OK] Caso 5: errores de envío solo generan advertencias.')

// -----------------------------------------------------------------------------
// Caso 6: dry-run -> calcula el mensaje sin tocar credenciales ni red.
// -----------------------------------------------------------------------------
reset()
state.env.NOTIFY_PIPELINE_DRY_RUN = 'true'
step = loadStep()
result = step.call(status: 'ABORTED', flow: mainFlow, version: '1.4.0', failedStage: 'Approve prod release')
assert result.dryRun && result.notify && !result.sent
assert result.payload.embeds[0].title.contains('ABORTADO')
assert state.credentialIds.isEmpty() && state.shCalls.every { !it.contains('curl') }
println('[OK] Caso 6: modo dry-run sin envío.')

// -----------------------------------------------------------------------------
// Caso 7: commit de merge de PR -> se usa HEAD^1; textos largos se recortan a los límites de Discord.
// -----------------------------------------------------------------------------
reset(gitOutput: "abc\nAutor\n" + ('x' * 3000))
step = loadStep()
result = step.call(status: 'FAILURE', flow: mainFlow, version: '1.4.0', failedStage: 'S' * 2000, details: 'Rollback a 1.3.0 ejecutado')
assert state.shCalls.any { it.contains('HEAD^1') && it.contains("Merge commit '") }
result.payload.embeds[0].fields.each { assert it.value.length() <= 1024 && it.name.length() <= 256 }
assert result.payload.embeds[0].title.length() <= 256
assert result.payload.embeds[0].fields.find { it.name == 'Detalle' }.value == 'Rollback a 1.3.0 ejecutado'
assert step.normalizeStatus('raro') == 'FAILURE' && step.normalizeStatus(null) == 'SUCCESS'
println('[OK] Caso 7: commit real tras merge de PR, campo de detalle y límites de Discord.')

println('=== notifyPipeline: 7 casos superados ===')
