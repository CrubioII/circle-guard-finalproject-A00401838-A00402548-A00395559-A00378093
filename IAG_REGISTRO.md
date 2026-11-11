# Registro de uso de IA generativa (anexo IAG)

| Campo | Valor |
|---|---|
| Equipo | SuperPoderosos |
| Curso | Ingeniería de Software V (09776), Universidad Icesi, período 2026-2 |
| Entrega | Proyecto Final CircleGuard, Parte 1 (Sprint 1) |
| **Nivel de uso declarado** | **Nivel 3: Colaboración con IAG** |
| Herramientas | Claude Code (modelo Claude Opus) como asistente en terminal sobre el repositorio, más los asistentes conversacionales que cada integrante registra en la sección 5 |
| Período | 1 al 11 de noviembre de 2026 (Sprint 0 y Sprint 1) |

## 1. Declaración

Declaramos que usamos IA generativa en **Nivel 3 (Colaboración con IAG)**, tal como lo permite el enunciado: nos apoyamos en ella para completar los entregables, y el equipo conserva la autoría, la decisión y la responsabilidad sobre todo lo integrado.

- Cada resultado generado fue revisado, ejecutado y, cuando hizo falta, corregido por un integrante antes de entrar a `main` mediante un Pull Request revisado por otro integrante.
- El equipo puede explicar y modificar cualquier configuración del repositorio. La sección 7 enumera las decisiones técnicas que defendemos en la sustentación.
- No compartimos con la IA secretos reales: contraseñas, la llave `.pem`, tokens de GitHub o credenciales de Nexus. Cuando una tarea los necesitaba, la IA trabajó con variables y credenciales de Jenkins por referencia, y el equipo cargó los valores reales.

## 2. Para qué usamos la IA generativa

| Uso | Ejemplos |
|---|---|
| Análisis de alcance | Contrastar las historias de Jira con el enunciado, la rúbrica y el estado real del repositorio y de Jenkins |
| Diseño y alternativas | Proponer planes de implementación con opciones y *trade-offs*; el equipo elegía (por ejemplo la «opción A» de US-13 y la «vía A» de US-31) |
| Implementación asistida | Scripts Bash, etapas del Jenkinsfile, Shared Library, compose por ambiente y pruebas |
| Pruebas y depuración | Diseñar casos de prueba, analizar logs de Jenkins y explicar la causa de un fallo |
| Documentación | Borradores de documentos técnicos, cuerpos de PR, este registro y el informe |

## 3. Análisis del alcance y coordinación del equipo

Antes de implementar revisamos las historias de Jira y su relación con el enunciado y la rúbrica. La IA nos ayudó a contrastar el estado del tablero con el repositorio remoto. Así confirmamos qué historias ya estaban resueltas, evitamos trabajo duplicado y repartimos el trabajo restante por áreas del proyecto.

Prompts representativos:

- «Revisa las historias asignadas en Jira y relaciónalas con lo que pide el enunciado y la rúbrica.»
- «Revisa en el repositorio si los cambios de esta historia ya fueron realizados y si falta algo frente a los criterios de aceptación.»
- «Indícame qué historias faltan, quién las tiene asignadas y de qué dependen.»

## 4. Implementación de pruebas y solución de problemas

El equipo lideró las pruebas automatizadas:

- pruebas unitarias con cobertura JaCoCo (US-31 de cobertura y US-32);
- pruebas de integración con Testcontainers (US-33);
- flujos E2E con Playwright (US-34 y US-17).

La IA nos ayudó a explorar cómo estructurar las pruebas sobre el middleware real (PostgreSQL, Redis y Kafka), a diseñar los flujos E2E sobre el cliente web y a entender el comportamiento del código base. Verificamos que cada cambio cumpliera los criterios de aceptación de su historia.

En este proceso aparecieron defectos del código base:

- la expiración del QR estaba configurada en milisegundos, así que el QR nacía caducado;
- el rol `GATE_STAFF` no tenía el permiso `gate:scan`;
- el cuestionario de salud enviaba las respuestas vacías.

Antes de integrar cada corrección contrastamos la evidencia con el enunciado y el código. Para el QR, por ejemplo, definimos 60 segundos porque es el valor que anuncian el controlador (`expiresIn`) y el cliente web.

Prompts representativos:

- «Dame el fragmento del enunciado donde se especifica este valor antes de cambiarlo.»
- «Analiza este registro de Jenkins, explica la causa probable del fallo y sugiere una corrección.»

## 5. Registro detallado de prompts

Cada fila registra el **contenido propio** que el equipo entregó a la IA, el **prompt** (literal cuando está disponible), lo que se obtuvo y **cómo lo verificamos**. Las filas de US-08, US-10, US-13, US-14, US-31, US-33 y US-19 corresponden a las sesiones de Claude Code de Juan Pablo Ordóñez sobre este repositorio.

### 5.1 US-08: docker-compose por ambiente con healthchecks y SemVer

| | |
|---|---|
| Contenido propio | Texto de la historia y criterios de aceptación copiados de Jira; restricción del equipo: imágenes `${REGISTRY_URL}/circleguard/<svc>:${IMAGE_TAG}`, nunca `latest` |
| Prompts | Implementar la US-08, pidiendo **el plan antes de cualquier cambio**. «se hicieron cambios en la rama vuelve a revisar». «apruebo el plan, prefiero la opción que recomiendas, verifica que se cumpla todo lo que requiere la US». «¿puedes darme el cuerpo del PR?» |
| Resultado | Tres `docker-compose.<env>.yml` autocontenidos (12 contenedores), healthchecks funcionales, grupos *readiness* por servicio, `validate-compose.sh` (53 verificaciones) y `smoke-up.sh` |
| Verificación | Ejecutamos `validate-compose.sh` y levantamos la pila con `smoke-up.sh`. Revisamos que ningún valor por defecto pudiera resolver a `latest` |

### 5.2 US-33: verificación sin implementar

| | |
|---|---|
| Contenido propio | Historia de integración entre servicios con Testcontainers |
| Prompt | «verifica si esta hu esta implementada, si no lo esta, no la implementes solo dime si esta o no implementada» |
| Resultado | Diagnóstico sin cambios de código: en ese momento la historia no estaba implementada. Después la completó otro integrante (PR #16) |
| Verificación | El equipo revisó el diagnóstico contra el repositorio y Jira |

### 5.3 US-13: despliegue automático a dev y promoción a stage tras E2E

| | |
|---|---|
| Contenido propio | Historia y criterios de aceptación; IPs de los nodos de US-05; decisión de no versionar la llave SSH |
| Prompts | Implementar US-13 con un plan previo. «¿qué necesitas para el acceso de jenkins a los nodos? ¿el archivo .pem?». «opción A y despliegue automático en cada build de main». «ya hice el commit, la US-17 con pruebas E2E ya se añadieron al main remoto, ¿puedes traer los cambios y resolver los conflictos?» |
| Decisiones del equipo | Opción A: suite E2E mínima con contratos `@deployed`, compatible con los flujos de US-17. Despliegue automático en cada build de `main`. La llave se carga como credencial `circleguard-env-ssh`, nunca en el repositorio ni en el chat |
| Resultado | `deploy/scripts/` (deploy, verify y E2E por túneles SSH), etapas del Jenkinsfile y `promotionDecision` en la Shared Library |
| Verificación | Validador del pipeline (casos 15 a 19), `test-deploy-scripts.sh` y despliegue local con `--local` contra la pila de `smoke-up.sh`. Resolvimos el *merge* con `main` revisando cada conflicto |

### 5.4 US-14: consulta de impacto

| | |
|---|---|
| Contenido propio | Mensaje del integrante responsable de US-14 sobre el parámetro `ROLLBACK_TARGET_VERSION` |
| Prompt | Preguntamos si ese cambio afectaba a US-13 |
| Resultado | Análisis de impacto, sin implementación («la us-14 no nos corresponde, sigamos con esta») |

### 5.5 US-31: aprobación manual y despliegue verificado a prod

| | |
|---|---|
| Contenido propio | Historia, criterios de aceptación y la política de cambios de US-18 (comentario o RFC obligatorio) |
| Prompts | Implementar US-31 con plan previo. «se llega por la via A, de momento no tengo los IDs de usuario, usa el identificador US-31 de igual forma, algo más: ¿es posible que dividas lo que implementes en distintos commits? si es posible recuerda hacer los commits sin el co-authored». «dame el cuerpo del PR» |
| Resultado | Etapas `Approve prod release`, `Deploy to prod` y `Verify prod health`, `prodApprovalDecision` y el conversor de salud a JUnit, en 5 commits separados |
| Verificación | Validador del pipeline (casos 20 a 22), `test-deploy-scripts.sh` (40 pruebas) y un **Jenkins 2.580.2 real** desechable con estos escenarios: aprobación, rechazo, falta de comentario, *Abort*, *timeout*, aprobadores vacíos y usuario no autorizado |

### 5.6 US-19: README operativo, diagramas, informe PDF y este registro

| | |
|---|---|
| Contenido propio | Historia de Jira, el enunciado `Proyecto_Final_CircleGuard.tex` y el borrador de bitácora del equipo |
| Prompt | «Quiero implementar completamente la siguiente HU, analiza bien el proyecto para completar la documentación» (más el texto de la historia) |
| Resultado | README reescrito como guía de reproducción, 3 diagramas SVG versionados, `PIPELINE_CICD.md`, `ARQUITECTURA_P1.md`, este anexo, un informe HTML compilado a PDF y un script de captura de evidencias |
| Verificación | Comprobamos cada URL, IP, puerto y comando contra los scripts y contra los servicios en ejecución. Las suites locales se ejecutaron otra vez y sus resultados están en el informe |

Actualización tras el *merge* de US-14 (notificaciones) a `main`:

| | |
|---|---|
| Contenido propio | Los commits nuevos de `main` (PR #21 y #24) |
| Prompt | «la rama main remota fue actualizada, puedes traer los cambios y actualizar la documentacion?» |
| Resultado | *Merge* de `main` sin conflictos y actualización del README, `PIPELINE_CICD.md`, el informe y este anexo: notificaciones en Discord, credencial `discord-webhook`, parámetro `NOTIFY_DISCORD` y el build #18 de `main` en verde |
| Verificación | Ejecutamos `run-notify-validation.sh` (8 casos) y consultamos la API de Jenkins: build #18 en `SUCCESS`, 0.2.0 en stage, notificación enviada (HTTP 204). La misma consulta mostró que el tag `v0.2.0` no llega a GitHub, y lo declaramos como brecha |

Actualización tras el *merge* de US-10, US-16, US-31 (seguridad) y US-01/US-03 a `main`:

| | |
|---|---|
| Contenido propio | Los commits nuevos de `main` (PR #7, #23, #25 y #26) |
| Prompt | «la documentacion esta desactualizada con main, volvamos a la rama docs/US-19-operative-README-logbook-IAG, resuelve los conflictos si los hay, y actualiza la documentacion» |
| Resultado | Conflicto del README resuelto conservando la versión de US-19 e incorporando en sus secciones SonarQube, la seguridad de Jenkins, la prueba de integración de US-16 y las actas de los sprints. Se actualizaron los diagramas (20 etapas), `PIPELINE_CICD.md`, `ARQUITECTURA_P1.md`, el informe y el script de capturas, que ahora inicia sesión en Jenkins con un API token |
| Verificación | Revisamos el Jenkinsfile, las pruebas y los documentos de `main` antes de afirmar cada cambio, y volvimos a ejecutar los validadores; los resultados están en el anexo A del informe |

### 5.7 US-31: seguridad de Jenkins y aprobadores de prod

| | |
|---|---|
| Contenido propio | El hallazgo de US-19 (Jenkins sin autenticación) y la decisión del equipo sobre las cuentas: IDs de los integrantes, `docente` de solo lectura, sin acceso anónimo y dos aprobadores de prod |
| Prompts | «empezemos con la seguridad de jenkins y los aprobadores, dime el plan de accion antes de comenzar a implementar para aprobarlo». «como determino los ID de usuarios? debo crearlos yo? […] sigamos la opcion que recomiendas para el acceso anonimo». «como hago lo de la seccion 4 y para que?» |
| Resultado | Cuentas locales y matriz de permisos en JCasC, aprobadores como variables globales, contraseñas generadas por `bootstrap-ci.sh` y entregadas como secretos de Docker Compose, un entrypoint que no arranca Jenkins sin ellas, el validador `validateJenkinsSecurity` y el procedimiento de despliegue en el servidor |
| Verificación | 32 verificaciones estáticas (que además fallan con 6 configuraciones inseguras), 65 pruebas del bootstrap y un **Jenkins 2.580.2 real** con 34 verificaciones y la actualización desde un Jenkins sin seguridad. El despliegue en `52.14.6.11` lo hizo un integrante por SSH |

### 5.8 US-10: integración de SonarQube con `main`

| | |
|---|---|
| Contenido propio | El PR #7 de US-10 (Juan Camilo Rubio Arboleda) con conflictos frente a `main` |
| Prompts | «resolvamos los conflictos del PR #7». «hice push de los cambios a la rama del pr pero los checks fallaron» |
| Resultado | Conflictos resueltos tomando como base el Jenkinsfile y la configuración de JaCoCo de `main`. Se movió el Quality Gate antes de publicar y desplegar, se dejó de fijar la Shared Library a la rama de US-10 y se adaptó `sonarQualityGate` para cargarse con `load` dentro del *sandbox* de Jenkins |
| Verificación | Validadores de US-10, del pipeline y de seguridad. Además reprodujimos el fallo en un Jenkins real: la versión enviada fallaba con `RejectedAccessException` (`new java.io.File`) y la corregida pasaba |

### 5.9 Prompts de los demás integrantes

Cada integrante agrega aquí sus prompts más relevantes con el mismo formato (contenido propio, prompt, resultado y verificación). Las historias de cada integrante se tomaron del historial de Git de `main`; ajústalas si la asignación de Jira es distinta:

| Integrante | Historias | Herramienta | Prompts y contenido propio |
|---|---|---|---|
| Juan Camilo Rubio Arboleda | US-02, US-04, US-05, US-07, US-09, US-11, US-12, US-18, US-30 | *(completar)* | *(completar)* |
| Esteban Cuéllar | US-14, US-17, US-33, correcciones del código base | *(completar)* | *(completar)* |
| Santiago Castillo | US-31 (cobertura), US-32, US-34 | *(completar)* | *(completar)* |

## 6. Reflexión crítica sobre las respuestas generadas

La IA aceleró el trabajo, pero varias de sus respuestas **eran incorrectas o incompletas y solo lo descubrimos al ejecutarlas**. Estos casos guiaron cómo trabajamos con ella:

1. **Una restricción de seguridad que no protegía (US-31).** La primera versión restringía la aprobación con el parámetro `submitter` del `input`. Pasaba todas las pruebas unitarias. Al probarla en un Jenkins real, una usuaria administradora que no estaba en la lista (`eve`) pudo aprobar: Jenkins no aplica `submitter` a los administradores. Lo corregimos validando al aprobador dentro del pipeline (commit `2d555d5`) y documentando `matrix-auth` como segunda capa.
   - *Aprendizaje:* una prueba con *mocks* valida lo que el autor cree que hace la plataforma, no lo que hace. Las compuertas de seguridad se prueban en la plataforma real.
2. **El *sandbox* de Jenkins cambia el comportamiento (US-31).** Para distinguir un *timeout* de un *Abort*, la IA propuso leer `FlowInterruptedException.getCauses()`. El *sandbox* lo bloquea, y un *timeout* quedaba registrado como `ABORTED`. Lo resolvimos midiendo el tiempo de espera. En el mismo trabajo, una referencia directa a esa clase en un `catch` rompía el validador de sintaxis Groovy. Lo reemplazamos por una comparación por nombre de clase que relanza las excepciones ajenas.
3. **Análisis sobre un estado desactualizado (US-08).** El primer análisis se hizo antes de que otro integrante subiera cambios a la rama. Tuvimos que pedir «vuelve a revisar».
   - *Aprendizaje:* antes de aceptar un diagnóstico, confirmamos contra qué *commit* se hizo.
4. **Valores por defecto que no eran del equipo.** La herramienta agrega por defecto una línea `Co-Authored-By` a los commits. Lo rechazamos: los commits, *pushes* y PR los hace cada integrante con su identidad, para que el factor de contribución individual refleje el trabajo real. Desde entonces la IA solo prepara el cambio y el mensaje.
5. **Documentar lo que existe, no lo que se planeó (US-19).** Al preparar el informe, la IA contrastó los documentos con el Jenkins en ejecución y encontró que:
   - el Jenkinsfile de `main` no tiene la etapa de SonarQube (la rama de US-10 no se fusionó);
   - no hay notificaciones de fallo;
   - el último build de `main` fallaba en un E2E;
   - Jenkins estaba configurado sin autenticación.

   Al 11 de noviembre, las cuatro están resueltas: notificaciones (US-14), build verde de `main` (#18), SonarQube (US-10) y autenticación (US-31).

   Algunos documentos anteriores afirmaban más de lo implementado. Decidimos declarar estas brechas en el informe (sección de brechas de `PIPELINE_CICD.md`) en lugar de ocultarlas, y priorizarlas en el siguiente sprint.
6. **Entornos que engañan.** En Windows, `bash` resolvía a WSL, `localhost` a IPv6 y `python3` al alias vacío de Microsoft Store. Varios fallos que parecían del código eran del entorno.
   - *Aprendizaje:* reproducir en el mismo entorno que el pipeline (contenedor o Git Bash) antes de cambiar código.
7. **Un secreto bien guardado puede filtrarse por otro lado (US-31).** La forma habitual de pasar contraseñas a un contenedor es como variables de entorno. Al revisar el diseño vimos que, como los builds corren en el mismo nodo que Jenkins, cualquier `sh 'env'` de una rama las habría impreso en el log. Por eso las entregamos como secretos de Docker Compose (archivos en `/run/secrets`) y lo comprobamos con un build real: `sh 'env'` no muestra ninguna. La misma prueba mostró algo que no esperábamos: cualquier integrante con `Job/Cancel` puede abortar la espera de prod. No es un riesgo, porque abortar nunca despliega, y quedó documentado.
8. **Lo que pasa un validador no siempre corre en Jenkins (US-10).** Al cambiar cómo se cargaba `sonarQualityGate` (con `load` desde el workspace), el validador local seguía en verde, pero el PR falló. En un Jenkins real reprodujimos el error: el *sandbox* bloquea `new java.io.File`, y además esa ruta no apuntaba al workspace del build. Corregimos el paso (pasos `fileExists`/`readFile`, sin parámetros por defecto) y agregamos al validador un caso que detecta esos patrones.
   - *Aprendizaje:* es el mismo aprendizaje del caso 1, ahora aplicado a un cambio de carga. Las restricciones de la plataforma se prueban en la plataforma.
9. **El valor real estuvo en las pruebas.** El contrato E2E «la vigencia real del QR coincide con `expiresIn`» lo propuso la IA, pero el defecto que protege (QR caducado al nacer) lo confirmamos leyendo el código y el enunciado. Las sugerencias de la IA solo valen lo que valen las pruebas que las respaldan.

En general, la IA rindió muy bien al redactar, al leer mucho código o muchos logs rápido y al proponer casos de prueba. Fue poco fiable en detalles de plataforma (permisos, *sandbox*, plugins) y en el estado real de la infraestructura. Por eso cada resultado pasó por ejecución real antes de integrarse.

## 7. Responsabilidad y comprensión

La IA fue una herramienta de apoyo, no un sustituto del trabajo del equipo. Las decisiones fueron nuestras:

- cómo repartir las historias;
- qué opción de cada plan seguir;
- qué valores usar en las correcciones;
- qué tareas aplazar por depender de otras historias o de la infraestructura.

El equipo puede explicar, entre otras:

- por qué se usa Testcontainers para probar contra el middleware real;
- por qué las correcciones de base de datos se hicieron con migraciones nuevas y no editando las existentes;
- cómo los flujos E2E simulan el backend o se ejecutan contra un ambiente mediante `BASE_URL` y túneles SSH;
- por qué se promueve la misma imagen `X.Y.Z` entre ambientes en lugar de recompilar;
- cómo se calcula SemVer desde Conventional Commits;
- por qué Jenkins despliega por SSH;
- por qué la aprobación de prod se valida dentro del pipeline además de con `submitter`;
- las causas de los fallos del pipeline.

Cada integrante realizó personalmente sus commits, *pushes* y pull requests. Los PR fueron revisados por otro integrante antes de fusionarse.
