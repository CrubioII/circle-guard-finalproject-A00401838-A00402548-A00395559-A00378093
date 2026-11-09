# Release v0.1.0 (2026-11-08)

Liberacion inicial con todos los cambios acumulados hasta la fecha:

## Nuevas funcionalidades (Features)
- `2c51de6` feat(infra): add multi-stage dockerfiles for US-06
- `de2d25d` feat(web): add multi-stage non-root Dockerfile and dynamic env config for US-07
- `95780c8` feat(infra): add idempotent CI/CD bootstrap script and compose stack for US-04
- `1bec680` feat(jenkins): add multibranch pipeline consuming shared library for US-30
- `8c62cf7` feat(jenkins): implement shared library for changed service detection in US-09

## Correcciones de defectos (Bug Fixes)
- `892fcb2` fix(test): configure H2 test datasource and Redis Testcontainers in promotion-service
- `569da3a` fix(test): fix controller unit tests and set disabledWithoutDocker on Testcontainers
- `3963f02` fix(ci): skip Docker-dependent tests in CI and resolve PR head SHA on merge builds
- `112accc` fix(jenkins): provide CI test JWT secret for identity-service tests
- `2387581` fix(jenkins): resolve commit SHA from workspace when checkout env vars are absent
- `d5bb324` fix(jenkins): make JCasC library and branch source runtime-compatible
- `247a79b` fix(build): track Gradle wrapper jar required by CI
- `f0eb101` fix(jenkins): align JCasC with current plugin APIs for US-30

## Documentacion
- `d54bcf1` docs(agile): define branching strategy, Excalidraw flow and PR template for US-02

## Mantenimiento y tareas menores
- `83c2d40` test(jenkins): validate GitHub Branch Source scan credential
- `6472c75` chore(git): ignore local PEM key files
- `15deab4` Initial commit

## Artefactos e imagenes inmutables asociadas

Las siguientes imagenes fueron construidas y etiquetadas para este release:
- `52.14.6.11:5000/circleguard/auth:0.1.0`
- `52.14.6.11:5000/circleguard/identity:0.1.0`
- `52.14.6.11:5000/circleguard/promotion:0.1.0`
- `52.14.6.11:5000/circleguard/form:0.1.0`
- `52.14.6.11:5000/circleguard/gateway:0.1.0`
- `52.14.6.11:5000/circleguard/notification:0.1.0`
- `52.14.6.11:5000/circleguard/file:0.1.0`
- `52.14.6.11:5000/circleguard/dashboard:0.1.0`
- `52.14.6.11:5000/circleguard/mobile:0.1.0`
