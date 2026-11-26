# Release v0.2.0 (Parte 2)

Primera versión desplegada en Kubernetes. Agrupa el Sprint 2: de v0.1.0 (8 de noviembre de 2026) al cierre de la Parte 2. La lista completa de commits está abajo y la genera `infra/scripts/generate-release-notes.sh`.

## Resumen

| Área | Cambio | Historias |
| :--- | :--- | :--- |
| Infraestructura | Terraform con módulos `network`, `compute`, `registry`, `storage` y `observability`, tres ambientes y estado remoto en S3 con bloqueo | US-20, US-35, US-36 |
| Plataforma | Clúster k3s por ambiente; middleware, 8 servicios y cliente web con Kustomize; Ingress con TLS; sondas de Actuator y HPA | US-21, US-37, US-38 |
| Pipeline | `terraform plan/apply`, Trivy de imágenes e IaC, despliegue y verificación en Kubernetes, ZAP baseline contra dev | US-22, US-38/39, US-44 |
| Patrones | Circuit Breaker y Retry (Resilience4j), configuración externa, reintentos con Dead Letter Topic en Kafka | US-23, US-40 |
| Observabilidad | Prometheus, Grafana técnico y de negocio, alertas críticas en Alertmanager, trazas en Jaeger, logs en Loki | US-24, US-25, US-41, US-42 |
| Seguridad | RBAC por servicio y para Jenkins, escaneo de secretos, TLS en el Ingress | US-26 |
| Pruebas | Locust con objetivos de p95, throughput y tasa de error | US-27 |
| Cambios | Rollback automático y manual en Kubernetes, registro por ambiente | US-28 |

## Cambios de comportamiento a tener en cuenta

- Los servicios Spring ya no reciben tráfico hasta que `/actuator/health/readiness` responde. Un pod que tarda más de 5 minutos en arrancar se reinicia.
- `gateway-service`, `form-service` y `promotion-service` pueden pasar de 1 a 3 réplicas por CPU.
- El pipeline publica el tag `vX.Y.Z` en GitHub. Desde esta versión el cálculo SemVer parte del último tag publicado y no vuelve a 0.1.0.
- Un ambiente nuevo necesita sus Secrets antes del primer despliegue: `deploy/k8s/scripts/create-secrets.sh --env <env> --generate --if-missing`.

## Rollback

Volver a 0.1.0 en Kubernetes: build de `main` con `ROLLBACK_ENV=<env>` y `ROLLBACK_TARGET_VERSION=0.1.0` (prod pide aprobación). Procedimiento y evidencia en `docs/operaciones/ROLLBACK_K8S_US28.md`.

## Commits incluidos

### Nuevas funcionalidades (Features)
- `cdfa290` feat(observability): add the Loki datasource and a logs dashboard filtered by environment and service for US-42
- `40a5294` feat(observability): collect the logs of every pod in the environment namespace with Alloy for US-42
- `86f1856` feat(observability): add a monolithic Loki with per environment retention for US-42
- `a8eafd6` feat(k8s): serve the Ingress over HTTPS with cert-manager and redirect HTTP for US-26
- `7474174` feat(k8s): give each service its own account and Jenkins a namespace-scoped deployer for US-26
- `dee9dea` feat(k8s): deploy the web client in each environment namespace for US-37
- `b2b209d` feat(ci): run the ZAP baseline scan against dev after the E2E stage
- `d7339ab` feat(security): add OWASP ZAP baseline scan with a high-risk threshold
- `fd23ab7` feat(ci): init the terraform pipeline with native S3 state locking instead of DynamoDB for US-36
- `fb99204` feat(terraform): move environments to the S3 remote backend with native state locking for US-36
- `26909b5` feat(k8s): expose the microservices through an Ingress per environment for US-37
- `50c3c59` feat(k8s): deploy the core microservices with ConfigMaps and Secrets for US-37
- `395d952` feat(observability): dashboards de negocio y alertas críticas US-41
- `87a935f` feat(terraform): add remote state bootstrap stack with a versioned encrypted S3 bucket for US-36
- `aa7c3f9` feat(observability): trazar form -> Kafka -> promotion -> notification con OpenTelemetry y Jaeger
- `e3b0976` feat(perf): add Locust scenarios for campus entry, surveys and stats with p95 thresholds
- `7a0b46a` feat(dashboard): wrap promotion calls with timeouts, retry and circuit breaker
- `601b4ec` feat(auth): wrap identity calls with timeouts, retry and circuit breaker
- `ee7c2c2` feat(k8s): add kubeconfig, secret and middleware deployment scripts for US-21
- `24b828c` feat(k8s): add stage and prod overlays with production sizing for US-21
- `6155f38` feat(k8s): add the openldap statefulset to complete the middleware for US-21
- `927b877` feat(k8s): add zookeeper and kafka statefulsets with tcp readiness for US-21
- `4d82c27` feat(k8s): add the neo4j statefulset with apoc and http readiness for US-21
- `856c4f0` feat(k8s): add postgres and redis statefulsets with the dev overlay for US-21
- `0ef764e` feat(k8s): add namespace isolation, quota and network policies for US-21
- `41eb24f` feat(observability): provision Grafana with the technical per-service dashboard for US-24
- `8c3ff59` feat(observability): add Prometheus with Kubernetes pod discovery per environment for US-24
- `196ec9b` feat(services): expose /actuator/prometheus with application and environment tags for US-24
- `b98eac1` feat(notification): add Kafka retry and dead letter topic pattern for US-40
- `fd5b249` feat(ci): add automatic and manual rollback stages for US-28
- `30869a9` feat(k8s): add Kubernetes rollback with rollout undo or tag redeploy for US-28
- `ac77f09` feat(e2e): run deployed E2E through kubectl port-forward for US-39
- `5241a16` feat(ci): deploy and promote to Kubernetes from the pipeline for US-39
- `93ebc56` feat(ci): plan terraform on PRs and apply per environment in Jenkins for US-22
- `5cbc5f9` feat(ci): scan IaC and images with Trivy before publishing for US-38
- `ea49edf` feat(k8s): add kustomize release deploy and rollout verification script for US-39
- `8a1eeea` feat(ci): allow building and pushing images in separate steps for US-38
- `44e233b` feat(security): add blocking Trivy scan for images and IaC for US-38
- `adc5230` feat(terraform): add pipeline script for plan and apply per environment for US-22
- `53a7eda` feat(bootstrap): add script to load Jenkins and SonarQube credentials
- `4cabd08` feat(terraform): wire network and compute into dev, stage and prod for US-20
- `2936d61` feat(terraform): add reusable k3s compute module for US-20
- `bb70fde` feat(terraform): add reusable VPC network module for US-20
- `f700492` feat(terraform): add dev, stage and prod environments for US-35
- `68dde0d` feat(terraform): add reusable CloudWatch observability module for US-35
- `16e5385` feat(terraform): add reusable S3 storage module for US-35
- `4b486cb` feat(terraform): add reusable ECR registry module for US-35
- `42a0648` feat(jenkins): enable local accounts and matrix authorization in JCasC for US-31
- `0dc9f35` feat(ci): notify pipeline result with failed stage in Discord for US-14
- `21c89d6` feat(jenkins): add notifyPipeline step to send build results to Discord for US-14
- `148d3e8` feat(ci): add manual approval and verified prod deployment stages for US-31
- `24f64fc` feat(deploy): add health report to JUnit converter for US-31
- `ea727c4` feat(jenkins): add prod approval decision and release stages to shared library for US-31
- `7bf7fd9` feat(jenkins): add rollbackDeployment shared library step
- `eaa0cc7` feat(infra): add rollback script to restore last stable semver per environment
- `ec8a30d` feat(infra): add automatic deployment and promotion stage after E2E for US-13
- `aca4531` feat(ci): integrate Gradle JaCoCo coverage and SonarQube quality gate for US-10

### Correcciones de defectos (Bug Fixes)
- `2f0c502` fix(observability): request 25m CPU per component so Loki and Prometheus fit on the stage node
- `8080e22` fix(observability): move the environment overlays out of the base so kustomize renders them for US-42
- `5551e45` fix(deploy): read the kubernetes verify report in the health junit converter for US-22
- `d2c1c30` fix(k8s): cover the web client and the E2E port-forward in the deployer RBAC for US-26
- `325d616` fix(deploy): use the pinned kubectl for the e2e port-forwards when the agent lacks it for US-22
- `c380bef` fix(deploy): download the pinned kubectl when the Jenkins agent does not have it for US-22
- `eafa2c0` fix(ci): pass an empty state bucket to terraform when CG_TF_STATE_BUCKET is unset for US-22
- `90d4b33` fix(ci): report Trivy image findings without blocking for US-39
- `7282177` fix(build): copy gradle.properties into the service image builds
- `9e70236` fix(terraform): keep the bootstrap lifecycle test working on Terraform 1.11 for US-36
- `27d4951` fix(dashboard): strip trailing slashes without a regex to avoid ReDoS
- `9bf8090` fix(observability): resolve Sonar naming and duplicated literal issues for US-41
- `c7d43a1` fix(ci): skip terraform stages when the aws credential is missing and gate apply behind CG_TERRAFORM_APPLY for US-22
- `6dc69d0` fix(notification): rename restricted identifier record in dead letter code for US-40
- `86cf9b1` fix(ci): run all module tests before SonarQube so PR analysis has binaries and coverage
- `e507589` fix(ci): skip SonarQube analysis for modules not compiled in the build
- `bee03e8` fix(k8s): move the prod sizing patches inline so trivy does not read partial manifests for US-21
- `b69126a` fix(k8s): run openldap with a read-only root filesystem for US-21
- `1241e72` fix(k8s): run neo4j, zookeeper and kafka with a read-only root filesystem for US-21
- `0d6cabb` fix(k8s): run postgres and redis with a read-only root filesystem for US-21
- `b3d6366` fix(security): document accepted Trivy IaC exceptions for US-38
- `6c9c7bf` fix(security): make Trivy scan compatible with Trivy 0.69.3 for US-38
- `e718967` fix(bootstrap): trust the Nexus registry over HTTP on the CI host
- `2a2f6a1` fix(jenkins): make sonarQualityGate loadable from the workspace in the Jenkins sandbox for US-10
- `a609c76` fix(promotion): configure JSON producer serializer so status events reach Kafka
- `aa4626b` fix(ci): never fail the build when the Discord notification fails for US-14
- `da3cef4` fix(jenkins): use CPS-compatible signatures in notifyPipeline for US-14
- `2d555d5` fix(jenkins): only listed approvers can decide prod releases for US-31
- `c94d846` fix(e2e): stabilize invalid login flow assertion
- `37dc6c1` fix(web): send questionnaire answers in health survey submission
- `73dd79f` fix(auth): grant gate:scan permission to gate staff role
- `e89bb5f` fix(auth): set qr token expiration to 60 seconds
- `c1b9394` fix(ci): restore US-31 coverage gate and JaCoCo publishing lost in merge with main
- `68fa190` fix(test): configure jwt secret for identity-service tests in US-10
- `789def9` fix(test): configure H2 test datasource and Redis Testcontainers in promotion-service

### Refactorizaciones
- `a31483b` refactor(auth): fix SonarQube issues in the identity client and login controller
- `86df3ec` refactor(notification): remove duplicated payload parsing for US-40
- `c9c30f1` refactor(ci): move stage bodies out of the pipeline block for US-22

### Infraestructura, Docker y CI/CD
- `8267c52` ci(security): accept the deployer Role service and ingress rights in Trivy for US-26
- `efe138c` ci(security): scan every pull request for secrets with gitleaks for US-26
- `8f0c7b0` build(terraform): keep the user_data templates with LF endings for US-22
- `0d46872` ci(terraform): validate terraform offline in a jenkins stage with a pinned verified binary for US-36
- `be289cc` build(dashboard): read the Resilience4j version from gradle.properties
- `ee8f31b` build(dashboard): add Resilience4j with externalized retry and circuit breaker config
- `a7c8662` build(auth): add Resilience4j with externalized retry and circuit breaker config
- `c01cb9a` ci(k8s): run the kubernetes manifest validation in a jenkins stage for US-21
- `3735d80` build(services): add Micrometer Prometheus registry to the 8 services for US-24
- `ab897fb` build(jenkins): install kubectl with checksum verification for US-39
- `fe084e0` build(jenkins): install terraform with checksum verification for US-22
- `12f66b5` ci(github): check pull request size and single story per PR
- `9e43cde` ci(e2e): Playwright framework and headless E2E stage in Jenkins for US-34

### Documentacion
- `6399215` docs(observability): document the CPU budget of the observability stack on the node
- `3ce7db2` docs(observability): document the log query path and the retention policy for US-42
- `e6d207e` docs(k8s): describe the web client in the kubernetes namespace for US-37
- `278f185` docs(ci): list the platform fixes deferred after the first real pipeline run for US-22
- `095d2c9` docs(security): describe the ZAP stage in the CI/CD pipeline
- `120eada` docs(security): document the ZAP baseline policy, reports and usage
- `e74b690` docs(terraform): note the Terraform version used by the Jenkins agent for US-36
- `f8b881d` docs(terraform): document the validate terraform stage and the real plans with the remote backend for US-36
- `c2ef69e` docs(terraform): add remote state and full AWS infrastructure diagrams for US-36
- `a10418f` docs(terraform): document the remote backend, native locking and concurrency evidence for US-36
- `a188e87` docs(ci): document the optional terraform credential and the apply switch for US-22
- `ce5e14f` docs(terraform): document the remote state bootstrap stack for US-36
- `6120082` docs(observability): documentar trazado distribuido y ejecucion verificada de US-25
- `2582c78` docs(patterns): document resilience and external configuration patterns for US-23
- `c1b893c` docs(k8s): document the k3s platform, namespaces, middleware and local cluster evidence for US-21
- `64c6241` docs(ops): document the metrics contract and observability setup for US-24
- `f40482b` docs(patterns): catalog existing design patterns with code references for US-23
- `e9b7ebc` docs(ops): document Kubernetes rollback and per-environment change log for US-28
- `033de3e` docs(ci): document Kubernetes deploy and promotion for US-39
- `b5c9f76` docs(ci): document terraform stages in the pipeline for US-22
- `1679bf4` docs(ci): document the Trivy gate for US-38
- `956c99e` docs: update hosts and instance ids after the AWS account migration
- `33474d3` docs(agile): add PR size rules to the template and branching strategy
- `5744d3e` docs(terraform): update US-35 real plan instructions with local backend and pending status for US-20
- `e38f398` docs(terraform): document network and compute modules, environment parameters and diagram for US-20
- `591e70d` docs(terraform): document platform modules, environment parameters and diagram for US-35
- `2bf35ab` docs(report): screenshot edited
- `86efe7a` docs(report): documentation updated
- `97b4788` docs(report): documentation updated
- `2210c7b` docs(report): documentation updated
- `abafa11` docs(report): change report format to markdown
- `cb450dd` docs(report): README report, diagrams and IAG logbook updated for US-19
- `4330b84` docs(ops): document Discord pipeline notifications for US-14
- `a072cc8` docs(agile): document Sprint 0 and Sprint 1 agile ceremonies and framework (US-01, US-03)
- `bf059e8` docs(report): README updated added report, diagrams and IAG logbook for  US-19
- `40500ba` docs(infra): document manual prod approval and verified release for US-31
- `80ba50a` docs(infra): document rollback mechanism and usage

### Mantenimiento y tareas menores
- `4fddd6b` test(observability): validate log collection, filters and retention without a cluster for US-42
- `5f8dd43` test(deploy): cover the kubernetes health report conversion for US-22
- `3c2d1ff` test(deploy): check the kubectl fallback of the e2e runner for US-22
- `5bb6620` chore(terraform): add the IAM policy for the terraform apply identity for US-22
- `c224197` test(ci): cover the null state bucket and the kubectl fallback for US-22
- `6acefc5` test(ci): cover the ZAP stage order and its non-blocking policy
- `4fcff59` test(security): cover ZAP targets, high-risk threshold and SSH access
- `2729579` test(terraform): verify that concurrent applies cannot take the same state lock for US-36
- `ceb1f29` chore(terraform): ignore local offline provider copies for US-36
- `703fc66` test(perf): add smoke, load and stress runner with HTML and CSV reports
- `0c43d1b` test(dashboard): cover retry, circuit breaker and fallback on promotion outage
- `adccf9d` test(auth): cover retry, circuit breaker and 503 on identity outage
- `c346a89` test(k8s): validate the rendered overlays offline with pinned verified tools for US-21
- `4438378` test(observability): add reproducible validation for metrics, Prometheus and Grafana for US-24
- `ff7981f` test(ci): cover Kubernetes rollback and the manual rollback stage for US-28
- `fcad087` test(ci): validate deploy platform selection and k8s stages for US-39
- `8f065aa` test(ci): validate terraform stages and apply gates for US-22
- `0173fc4` test(terraform): cover the terraform pipeline script with a stub binary for US-22
- `71e9dbe` test(ci): validate Trivy gate and scan script for US-38
- `1a48b31` test(k8s): cover release rendering and rollout verification for US-39
- `3b64550` test(infra): update expected hosts after the AWS account migration
- `03d1766` chore(infra): point pipeline and scripts to the new AWS account hosts
- `07434af` test(terraform): verify network and compute modules and add local-backend real plan for US-20
- `a6165fc` test(terraform): add plan verification script with plaintext credential scan for US-35
- `a01208e` test(promotion): add form -> Kafka -> promotion Testcontainers integration test for US-16
- `459664f` test(jenkins): add reproducible validation for notifyPipeline for US-14
- `bc4ffa2` test(infra): cover rollback scenarios with stubbed docker and ssh executor
- `48a2b5a` test(e2e): add qr access validation flow with playwright
- `9bc2c38` test(e2e): add health questionnaire submission flow with playwright
- `79b4425` test(e2e): add login flow with playwright
- `a87f090` test(identity): add postgresql testcontainers integration test for identity vault
- `68ec3fb` test(auth): add postgresql testcontainers integration test for rbac repository
- `76a5aa7` test(gateway): add redis testcontainers integration test for qr signature and expiry
- `8a91846` test(coverage): unit tests for gateway and complementary services for US-32
- `38a692c` test(coverage): unit tests to reach >=60% JaCoCo line coverage in core services for US-31
- `08db86c` chore(github): simplify pull request template without emojis

### Artefactos e imagenes inmutables asociadas

El pipeline publica estas imágenes con la etiqueta de esta versión cuando construye 0.2.0:
- `18.117.90.15:5000/circleguard/auth:0.2.0`
- `18.117.90.15:5000/circleguard/identity:0.2.0`
- `18.117.90.15:5000/circleguard/promotion:0.2.0`
- `18.117.90.15:5000/circleguard/form:0.2.0`
- `18.117.90.15:5000/circleguard/gateway:0.2.0`
- `18.117.90.15:5000/circleguard/notification:0.2.0`
- `18.117.90.15:5000/circleguard/file:0.2.0`
- `18.117.90.15:5000/circleguard/dashboard:0.2.0`
- `18.117.90.15:5000/circleguard/mobile:0.2.0`
