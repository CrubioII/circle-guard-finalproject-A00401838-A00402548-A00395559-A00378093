# Manual de operaciones de CircleGuard (US-48 CA3)

Procedimientos para arrancar, desplegar, revertir, atender alertas y destruir la plataforma. Cada sección enlaza al documento de detalle. Las secciones de observabilidad y Kubernetes se completan con lo que entreguen US-21, US-37 y US-43.

Nodos actuales (cuenta AWS migrada el 21 de noviembre de 2026, Región `us-east-2`):

| Nodo | Instancia | IP pública |
| :--- | :--- | :--- |
| CI (Jenkins, SonarQube, Nexus) | `i-061a73505a3aa1baa` | `18.117.90.15` |
| dev | `i-018eeb2ef96a6d94d` | `52.15.165.116` |
| stage | `i-05022e77d42dfafe5` | `52.14.89.125` |
| prod | `i-00e21144a1c89b8a5` | `77.113.211.62` |

Las IP públicas no son elásticas: si una instancia se detiene y vuelve a arrancar, cambia su IP. En ese caso hay que actualizar las variables globales de Jenkins `CG_DEV_HOST`, `CG_STAGE_HOST`, `CG_PROD_HOST` y `CG_REGISTRY_URL` (no hace falta tocar el repositorio). Si la que cambia es la del nodo de CI, además hay que actualizar el webhook de GitHub (paso 4 de la sección 1).

## 1. Arranque

1. Encender las instancias (consola de EC2 o `aws ec2 start-instances --instance-ids <ids>` con el perfil del proyecto) y anotar las IP nuevas.
2. Comprobar el plano de control:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://18.117.90.15:8080/login              # 200
   curl -s http://18.117.90.15:9000/api/system/status                                   # {"status":"UP"}
   curl -s -o /dev/null -w '%{http_code}\n' http://18.117.90.15:8081/service/rest/v1/status  # 200
   ```

3. Si cambió alguna IP, actualizar las variables globales de Jenkins (Administrar Jenkins > System > Global properties).
4. Si cambió la IP del nodo de CI, actualizar el webhook de GitHub. Sin este paso GitHub sigue avisando a la IP vieja y Jenkins no construye los push ni los PR nuevos. Hace falta permiso de admin en el repositorio. Hay dos formas:
   - En GitHub: Settings > Webhooks, editar el webhook de Jenkins y poner como Payload URL `http://<ip-ci>:8080/github-webhook/` (con la barra final). Con Redeliver en Recent Deliveries se comprueba que responde 200.
   - Con el script [`setup-github-webhook.sh`](../../jenkins/ci/setup-github-webhook.sh), que actualiza el webhook existente en vez de crear otro. El token necesita los scopes `repo` y `admin:repo_hook` (con `--dry-run` muestra lo que haría sin tocar GitHub):

     ```bash
     GITHUB_TOKEN=<token> JENKINS_URL=http://<ip-ci>:8080 ./jenkins/ci/setup-github-webhook.sh
     ```

   El webhook nuevo solo cubre los eventos que lleguen después. Para que Jenkins detecte los PR abiertos mientras apuntaba a la IP vieja, abrir el job `circleguard-monorepo` y ejecutar Scan Repository Now.
5. Para levantar el plano de control desde cero: [`BOOTSTRAP_CI_US04.md`](../arquitectura/BOOTSTRAP_CI_US04.md) y [`configure-jenkins-credentials.sh`](../../infra/bootstrap/configure-jenkins-credentials.sh). Para los ambientes: [`BOOTSTRAP_ENV_US05.md`](../arquitectura/BOOTSTRAP_ENV_US05.md).

## 2. Despliegue

El camino normal es un merge a `main`: el pipeline construye, escanea con Trivy, publica en Nexus, despliega en dev, corre los E2E, promueve a stage y espera la aprobación de prod. Detalle en [`PIPELINE_PLATAFORMA_US22_US38_US39.md`](../arquitectura/PIPELINE_PLATAFORMA_US22_US38_US39.md), [`DEPLOY_PROMOTION_US13.md`](../arquitectura/DEPLOY_PROMOTION_US13.md) y [`PROD_APPROVAL_US31.md`](../arquitectura/PROD_APPROVAL_US31.md).

Aprobar un release a prod: en el build de main, etapa `Approve prod release`, elegir `APROBAR`, la versión validada y escribir el RFC o comentario. Solo pueden responder los usuarios de `CG_PROD_APPROVERS`.

Despliegue manual (fuera del pipeline):

```bash
# Docker Compose (Parte 1)
SSH_KEY=~/.ssh/proyectoIngeClave.pem bash deploy/scripts/environment.sh deploy --env stage --version X.Y.Z --host 52.14.89.125
SSH_KEY=~/.ssh/proyectoIngeClave.pem bash deploy/scripts/environment.sh verify --env stage --version X.Y.Z --host 52.14.89.125

# Kubernetes (Parte 2)
bash deploy/k8s/scripts/get-kubeconfig.sh --env stage && export KUBECONFIG=~/.kube/circleguard-stage.yaml
bash deploy/scripts/k8s-deploy.sh deploy --env stage --version X.Y.Z
bash deploy/scripts/k8s-deploy.sh verify --env stage --version X.Y.Z
```

Cambios de infraestructura: siempre por PR que toque `infra/terraform`. El PR muestra el plan archivado; el merge aplica en dev y stage, y en prod después de la aprobación.

## 3. Rollback

| Caso | Cómo |
| :--- | :--- |
| Falla el rollout en Kubernetes | Automático: el pipeline hace `kubectl rollout undo` y falla la etapa |
| Rollback manual desde Jenkins | `Build with Parameters` en main con `ROLLBACK_ENV` y, si se quiere, `ROLLBACK_TARGET_VERSION`. En prod pide aprobación |
| Por terminal | `infra/scripts/rollback.sh rollback <env> [--to X.Y.Z] --platform k8s` o, con Compose, `--host <ip>` |

Detalle: [`ROLLBACK_K8S_US28.md`](ROLLBACK_K8S_US28.md) y [`ROLLBACK_US14.md`](ROLLBACK_US14.md). Cada rollback se anota en [`REGISTRO_CAMBIOS_POR_AMBIENTE.md`](../release-notes/REGISTRO_CAMBIOS_POR_AMBIENTE.md).

## 4. Alertas e incidentes

- Pipeline: Discord, canal `#pipeline` ([`NOTIFICACIONES_US14.md`](NOTIFICACIONES_US14.md)). Un fallo indica la etapa y enlaza al log.
- Aplicación: alertas de Alertmanager y dashboards de Grafana de US-43 (servicio caído, tasa de errores 5xx, lag de Kafka o circuito abierto). Pendiente de enlazar cuando US-43 esté desplegado.
- Logs y trazas: Loki (US-44) y Jaeger (US-25), con el `traceId` en los logs para saltar de un log a su traza.

Ante una alerta en prod: confirmar en Grafana qué servicio falla, revisar si coincide con un despliegue reciente (registro de cambios y `k8s-deploy.sh status --env prod`) y, si es así, hacer rollback antes de investigar.

## 5. Escaneos y calidad

- Trivy corta el pipeline con hallazgos HIGH o CRITICAL. Para aceptar una excepción, agregarla a [`.trivyignore`](../../.trivyignore) en un PR con justificación, responsable y fecha de revisión.
- SonarQube exige 60% de cobertura de líneas en los servicios núcleo ([`JENKINS_SONARQUBE_JACOCO_US10.md`](../agil/JENKINS_SONARQUBE_JACOCO_US10.md)).

## 6. Apagado y destrucción

Al terminar una sesión de trabajo o evaluación, detener las instancias que no se usen (costos en [`docs/costos/COSTOS.md`](../costos/COSTOS.md)):

```bash
aws ec2 stop-instances --region us-east-2 --instance-ids i-018eeb2ef96a6d94d i-05022e77d42dfafe5
```

Destruir la infraestructura de Terraform de un ambiente (de prod hacia dev, y el backend de estado al final):

```bash
cd infra/terraform/envs/<env>
terraform init -backend-config=backend.hcl
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

El bucket del estado tiene versionado y no se borra con los ambientes: se elimina a mano después, cuando ya no quede ningún estado que proteger.
