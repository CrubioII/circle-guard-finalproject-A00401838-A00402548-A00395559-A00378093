# Registro de uso de IA generativa

**Equipo:** SuperPoderosos
**Curso:** Ingeniería de Software V, 2026-2, Proyecto Final CircleGuard – Parte 1 (Sprint 1)
**Nivel de uso declarado:** Nivel 3 (Colaboración con IAG)

## 1. Uso de IA generativa y su propósito

El equipo utilizó herramientas de IA generativa para analizar el enunciado y las historias de usuario, explorar alternativas de implementación, apoyar en la escritura de pruebas, investigar errores del pipeline y apoyar en la documentación.

## 2. Uso de IA generativa

### 2.1. Análisis del alcance y coordinación del equipo

Revisamos las historias de usuario de Jira y su relación con el enunciado y la rúbrica antes de implementar. Utilizamos IA generativa para contrastar el estado del tablero con el repositorio remoto, lo que nos permitió confirmar qué historias ya estaban resueltas y evitar trabajo duplicado. Con esa información el equipo distribuyó el trabajo restante según las áreas del proyecto.

Prompts (instrucciones):

- "Revisa las historias asignadas en Jira y relaciónalas con lo que pide el enunciado y la rúbrica."
- "Revisa en el repositorio si los cambios de esta historia ya fueron realizados y si falta algo frente a los criterios de aceptación."
- "Indícame qué historias faltan, quién las tiene asignadas y de qué dependen."

### 2.2. Implementación de pruebas y solución de problemas

El equipo lideró la implementación de las pruebas automatizadas del proyecto: pruebas unitarias con cobertura, pruebas de integración con Testcontainers y flujos E2E con Playwright. Utilizamos IA generativa para explorar cómo estructurar las pruebas de integración sobre los servicios y su middleware (PostgreSQL, Redis y Kafka), diseñar los flujos E2E sobre el cliente web y analizar el comportamiento del código existente. Verificamos que cada modificación cumpliera los criterios de aceptación de su historia de usuario.

Durante este proceso se identificaron errores del código base, por ejemplo: la expiración del QR configurada en milisegundos (0,3 s), el rol `GATE_STAFF` sin el permiso `gate:scan` y el cuestionario de salud que enviaba las respuestas vacías. Antes de integrar cada corrección contrastamos la evidencia en el enunciado y en el código; por ejemplo, para el QR se definió una vigencia de 60 segundos porque es el valor que usan el controlador y el cliente web.

Prompts (instrucciones):

- "Dame el fragmento del enunciado donde se especifica este valor antes de cambiarlo."
- "Analiza este registro de Jenkins, explica la causa probable del fallo y sugiere una corrección."

### 2.3. Documentación y trazabilidad

Nos encargamos de que cada historia quedara trazable: commits con Conventional Commits y referencia a la historia de Jira, pull requests con la plantilla del equipo y estados del tablero actualizados. La IA generativa nos ayudó a redactar las descripciones de los pull requests y los comentarios de avance en Jira, y a organizar el resumen de pendientes del equipo.

Prompt (instrucción):

- "Dame un resumen de lo que falta para que el equipo sepa, resaltando al responsable de cada parte."

## 3. Organización y contribuciones del equipo

El equipo distribuyó el trabajo por historias de usuario y comunicó qué historias abordaría cada integrante para evitar conflictos. Trabajamos en ramas independientes por historia, dividiendo cada una en varios commits con Conventional Commits, y cada integrante realizó personalmente sus commits, pushes y pull requests. Nos apoyamos en la IA generativa para encontrar mejores formas de resolver cada tarea, teniendo en cuenta los criterios de aceptación. Los pull requests fueron revisados por otros integrantes para coordinar el trabajo y evitar conflictos.

El equipo tomó las decisiones del proyecto: cómo distribuir las historias, qué valores usar en las correcciones y qué tareas aplazar por depender de otras historias o de la infraestructura. La IA generativa aportó análisis y sugerencias, pero la responsabilidad de seleccionar e integrar los cambios recayó siempre en el equipo.

## 4. Responsabilidad y comprensión

La IA generativa funcionó como una herramienta de apoyo, no como un sustituto del trabajo del equipo. Somos capaces de explicar las decisiones técnicas que forman parte de nuestro trabajo, como el uso de Testcontainers para probar contra el middleware real, por qué las correcciones de base de datos se hicieron con migraciones nuevas y no editando las existentes, cómo los flujos E2E simulan el backend o se ejecutan contra un ambiente mediante `BASE_URL`, y las causas de los fallos del pipeline. El equipo fue responsable de revisar las sugerencias, decidir cuáles integrar, realizar las correcciones y verificar los resultados finales.
