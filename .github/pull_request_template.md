<!--
Reglas del PR (las revisa el check `pr-rules`, ver docs/agil/BRANCHING_STRATEGY.md sección 7):
  R1. Título en Conventional Commits: tipo(alcance): descripción
  R2. Una sola historia por PR (US-XX en el título o en la rama)
  R3. Máximo 400 líneas de código y 25 archivos (pruebas y docs no cuentan)
  R4. Resumen, Cómo probarlo y Criterios de aceptación llenos
Si la historia no cabe, divídela en PR apilados (cada uno sobre el anterior).
-->

## Trazabilidad con Jira

- Historia de Usuario: US-XX
- Incidencia en Jira: SCRUM-XX (https://circleguard777.atlassian.net/browse/SCRUM-XX)
- Depende de: <!-- PR anterior si este PR está apilado, o "ninguno" -->

## Resumen

<!-- Qué cambia y por qué, en dos o tres frases. -->

## Cambios realizados

-

## Cómo probarlo

<!-- Comandos exactos que el revisor puede correr y qué debe ver. -->

## Criterios de aceptación

<!-- Un renglón por criterio de la historia: cubierto aquí, en otro PR o pendiente (y por qué). -->

- [ ] CA1:

## Tipo de cambio (Conventional Commits / SemVer)

- [ ] feat: nueva funcionalidad (incrementa MINOR)
- [ ] fix / perf / refactor / build: corrección o ajuste interno (incrementa PATCH)
- [ ] feat! / BREAKING CHANGE: cambio incompatible (incrementa MAJOR)
- [ ] docs / test / ci / chore: documentación, pruebas o configuración

## Justificación de tamaño

<!-- Solo con la etiqueta size-exception: por qué este PR no se puede dividir. Si no aplica, borra esta sección. -->

## Checklist de revisión

- [ ] El PR toca una sola historia y el check `pr-rules` está en verde.
- [ ] Los commits siguen Conventional Commits y cada uno compila o pasa sus pruebas por sí solo.
- [ ] Se corrieron las pruebas indicadas en "Cómo probarlo".
- [ ] Cuenta con al menos 1 aprobación de otro integrante del equipo.
