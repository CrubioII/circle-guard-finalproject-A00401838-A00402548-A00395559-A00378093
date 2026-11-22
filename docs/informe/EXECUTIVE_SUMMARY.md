# CircleGuard: Executive Summary (Part 2)

Team SuperPoderosos (Group 5): Juan Pablo Ordoñez, Juan Camilo Rubio, Esteban Cuéllar and Santiago Castillo. Software Engineering V, Universidad Icesi, 2026-2.

CircleGuard is a university contact-tracing system. It groups people who share spaces into circles and applies health fences without exposing anyone's identity. It runs as eight Spring Boot microservices and an Expo web client, backed by PostgreSQL, Neo4j, Kafka, Redis and OpenLDAP.

## What Part 1 delivered

A Jenkins multibranch pipeline that builds and tests only the services that changed, blocks on a SonarQube quality gate, publishes immutable SemVer images to a private Nexus registry, deploys to dev, runs Playwright end-to-end tests against the real services, promotes to stage and waits for a named approver before production. Rollback to the last stable version and Discord notifications were part of the same pipeline.

## What Part 2 adds

- Infrastructure as code with Terraform: reusable modules for network, compute (k3s), container registry, storage and observability, with remote state in S3 and DynamoDB locking, and the same code for dev, stage and prod.
- Kubernetes: every environment gets its own namespace with network policies, resource quotas and the middleware as stateful workloads.
- A stronger pipeline: Terraform plan on every infrastructure pull request, automatic apply in dev and stage and approval-gated apply in production; a Trivy scan that stops the build on high or critical findings in images or infrastructure code; deployment with `kubectl apply -k` verified by `kubectl rollout status`, with automatic rollback when a rollout fails.
- Resilience and configuration patterns (circuit breaker and retry, feature toggles, a third pattern for Kafka or QR validation) on top of the patterns the system already had, which are documented with code references.
- Observability with Prometheus, Grafana, Alertmanager, Jaeger and Loki, plus load testing with Locust and dynamic security testing with OWASP ZAP.

## Key decisions

The team kept the Part 1 Docker Compose path working while the cluster was built, and made the deployment platform a pipeline parameter. That kept every merge to main deployable during the migration. Each change still reaches production only after the same version passed dev, the end-to-end tests and stage, and after an authorized person approved it with a change request reference.

## Cost

Four `m7i-flex.large` instances cost about 300 USD per month at list prices. Non-production environments can be stopped when not in use, and the whole platform can be removed with `terraform destroy`.

## Status at submission

The status of each deliverable, with links to its evidence, is in `docs/agil/SPRINT_2_CEREMONIAS.md` (Sprint Review section).
