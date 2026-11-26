# CircleGuard: Executive Summary

CircleGuard is a campus health platform with eight Spring Boot microservices and an Expo web client. Students check in at campus gates and fill out health questionnaires. When someone reports a positive case, the system fences their contact circle and sends notifications. This project, built for Ingeniería de Software V at Universidad Icesi, takes CircleGuard from source code to a production-style delivery platform on AWS.

**Part 1** delivered the CI/CD baseline: a Jenkins multibranch pipeline with a shared library, SonarQube quality gates with JaCoCo coverage, immutable images published to Nexus, semantic versioning, automatic deployment to dev, gated promotion to stage, and manual approval for production.

**Part 2** moved the platform to infrastructure as code and Kubernetes:

- **Infrastructure.** Terraform declares the network, compute, registry, storage and observability resources as reusable modules. Dev, stage and prod use the same modules with different variables, and the state lives in S3 with locking.
- **Orchestration.** Each environment runs a k3s cluster with its own namespace. The middleware (PostgreSQL, Neo4j, Kafka, Redis, OpenLDAP), the eight services and the web client are deployed with Kustomize. The setup includes ConfigMaps, Secrets, a TLS Ingress, Actuator-based health probes and CPU autoscaling.
- **Pipeline.** Jenkins runs `terraform plan/apply` (production requires approval), scans images and IaC with Trivy, deploys to Kubernetes, verifies the rollout, rolls back automatically on failure, runs an OWASP ZAP baseline scan against dev and reports failures to Discord.
- **Design patterns.** Circuit Breaker and Retry with Resilience4j, external configuration, and Kafka retries with a dead letter topic. Each one is documented with its trade-offs and tested with injected failures.
- **Observability.** Prometheus and Grafana provide technical and business dashboards (containment time, promotions per minute, check-ins), and Alertmanager sends four critical alerts by email. Jaeger traces requests across form, Kafka, promotion and notification, and Loki collects the logs.
- **Security.** Each service has its own service account, Jenkins can only deploy to its namespace, production approval is limited to named approvers, the code is scanned for secrets and the Ingress serves HTTPS.

**Cost.** With everything running around the clock, the setup would cost about USD 310 per month at list price: four `m7i-flex.large` instances plus storage and public IPs. In practice, November usage on the project account was USD 21.82, all covered by credits, because instances ran only part of the time. Everything is removed with `terraform destroy` after the evaluation.

**Lessons learned.** Hand-made fixes on servers (registry settings, Secrets) caused the most trouble when environments were rebuilt, so they were moved into code. A pipeline that has grown large needs structure early: the Jenkinsfile reached the JVM's 64 KB method limit and had to be split into methods. Finally, a free-tier vCPU quota is a real design constraint. One node per environment and strict resource quotas came directly from it.
