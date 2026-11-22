# Pipeline de plataforma: Terraform, Trivy y Kubernetes (US-22, US-38, US-39)

Épica EPIC-11 (pipeline incrementado, entregable E2.3). Responsable: Juan Camilo Rubio.

El Jenkinsfile de la Parte 1 compilaba, probaba, publicaba en Nexus y desplegaba con Docker Compose por SSH. En la Parte 2 se le agregan tres cosas: Terraform con aprobación antes de prod, un escaneo de Trivy que corta el build y una segunda plataforma de despliegue, Kubernetes, que reutiliza las mismas compuertas de dev, stage y prod.

La decisión de qué etapas corren vive en [`jenkins/vars/platformFlow.groovy`](../../jenkins/vars/platformFlow.groovy). El Jenkinsfile lo carga desde el workspace con `load` (igual que `sonarQualityGate`), así cada rama prueba su propia versión. La lógica se valida sin Jenkins con `bash jenkins/test/run-platform-validation.sh`.

## Flujo en main

```
Detect -> Compile/Test -> Sonar -> Validate Compose (+ pruebas de scripts de plataforma)
       -> Terraform Plan (dev, stage, prod)        solo si cambia infra/terraform
       -> Trivy IaC Scan (infra/terraform, deploy/k8s)
       -> Build Images -> Trivy Image Scan (9 imágenes) -> Publish Images to Nexus
       -> Terraform Apply dev -> Deploy to dev -> Verify dev -> E2E against dev
       -> Terraform Apply stage -> Promote to stage -> Verify stage
       -> Approve prod release (US-31) -> Terraform Apply prod -> Deploy to prod -> Verify prod
```

En un Pull Request solo corren `Terraform Plan` (si el PR toca Terraform) y `Trivy IaC Scan`. Un PR nunca aplica Terraform ni despliega.

## US-22: Terraform en Jenkins

| Criterio | Cómo se cumple |
| :--- | :--- |
| CA1: `plan` en cada PR que modifique `infra/terraform/`, archivado | `platformFlow.planPlatform` marca `runTerraformPlan` cuando cambia un `.tf`, `.tfvars`, `.hcl` o script de `infra/terraform` (un README no cuenta). La etapa `Terraform Plan` corre [`tf-pipeline.sh plan`](../../infra/terraform/scripts/tf-pipeline.sh) para los tres ambientes y archiva `reports/terraform/<env>-plan.txt`, `-plan.json` y `-summary.json` |
| CA2: `apply` automático en dev y stage; prod espera el `input` de US-31 | `Terraform Apply dev` corre antes de desplegar dev. `Terraform Apply stage` exige que dev haya pasado despliegue, healthchecks y E2E. `Terraform Apply prod` va después de `Approve prod release` y solo corre si `prodApproval.deploy == true`, es decir, con los aprobadores de `CG_PROD_APPROVERS` |

`apply` aplica el archivo `reports/terraform/<env>.tfplan` que generó `plan` en la misma ejecución. Si no existe, el script sale con código 3: no se aplica nada que no se haya planificado y archivado. El resultado por ambiente queda en `reports/ci/terraform-apply.json`.

El backend es el de US-20 (S3 + DynamoDB en la Región del proyecto). `tf-pipeline.sh` arma la configuración al iniciar, sin datos de la cuenta en Git: el bucket sale de `CG_TF_STATE_BUCKET` o, si está vacío, de `circleguard-terraform-state-<ID_CUENTA>` con `aws sts get-caller-identity`.

`FORCE_TERRAFORM=true` corre plan (y apply en main) aunque el commit no toque Terraform, por ejemplo para detectar drift.

## US-38: Trivy bloqueante

| Criterio | Cómo se cumple |
| :--- | :--- |
| CA1: `trivy image` sobre las 9 imágenes y `trivy config` sobre `infra/terraform` y `deploy/k8s` | [`trivy-scan.sh`](../../infra/scripts/trivy-scan.sh) en dos etapas. `Trivy IaC Scan` corre en todo build pesado (PR y main). `Trivy Image Scan` corre en main entre `Build Images` y `Publish Images to Nexus`, así una imagen vulnerable nunca llega al registro |
| CA2: `HIGH,CRITICAL` con `--exit-code 1`; excepciones en `.trivyignore` | La tabla de cada objetivo usa `--severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore`. En imágenes se agrega `--ignore-unfixed`. El script escanea todos los objetivos y al final falla si alguno tuvo hallazgos, para que el reporte quede completo. [`.trivyignore`](../../.trivyignore) explica qué se exige para aceptar una excepción |
| CA3: reportes publicados en Jenkins | `reports/trivy/<objetivo>.txt` y `.json`, `summary-config.json`, `summary-image.json` como artefactos, y `reports/trivy/junit/*.xml` en el reporte de pruebas del build |

Para separar construcción y publicación, [`publish-docker-images.sh`](../../infra/scripts/publish-docker-images.sh) acepta `DO_PUSH=false` (solo construye) y `PUSH_ONLY=true` (solo publica lo ya construido y escaneado). `ENABLE_TRIVY_GATE=false` desactiva el escaneo en una ejecución manual.

## US-39: despliegue y promoción en Kubernetes

| Criterio | Cómo se cumple |
| :--- | :--- |
| CA1: `kubectl apply -k` por overlay con la etiqueta SemVer de US-12 | [`k8s-deploy.sh deploy`](../../deploy/scripts/k8s-deploy.sh) genera `build/k8s-release/<env>/kustomization.yaml`, que toma `deploy/k8s/overlays/<env>` (US-21) como base y fija las 9 imágenes en `<registro>/circleguard/<img>:X.Y.Z`. Rechaza `latest` |
| CA2: `kubectl rollout status` como verificación | `k8s-deploy.sh verify` espera el rollout de cada Deployment y StatefulSet de `circleguard-<env>` y comprueba que las imágenes de CircleGuard tengan la versión pedida. Si algo falla, el Jenkinsfile hace `rollout undo` (US-28) y la etapa falla |
| CA3: promoción automática a stage tras E2E y aprobación manual a prod | Son las mismas etapas de US-13 y US-31. Con k8s, los E2E de dev corren con `run-e2e.sh --k8s`, que abre `kubectl port-forward` a los Services en vez del túnel SSH |
| CA4: notificación de éxito y fallo | La de US-14 en Discord (`notifyPipeline`), que ya incluye versión, etapa fallida y enlace al log |

La plataforma se elige con el parámetro `DEPLOY_PLATFORM` (`default`, `compose`, `k8s`). `default` usa la variable global `CG_DEPLOY_PLATFORM` y, si no existe, `compose`. Elegir `k8s` sin los overlays de US-21 en el commit falla en la etapa de detección. Cuando los manifiestos de servicios estén en main, basta con definir `CG_DEPLOY_PLATFORM=k8s` en Jenkins.

Cada despliegue anota los Deployments con `kubernetes.io/change-cause` (versión y número de build) y guarda la versión en el ConfigMap `circleguard-release` del namespace. `k8s-deploy.sh status --env <env>` muestra ambas cosas y el historial de revisiones.

## Configuración en Jenkins

| Elemento | Tipo | Uso |
| :--- | :--- | :--- |
| `aws-terraform` | Credencial usuario/contraseña (Access Key ID / Secret) | Terraform plan y apply. Debe ser una identidad con permisos solo sobre los recursos de CircleGuard |
| `kubeconfig-dev`, `kubeconfig-stage`, `kubeconfig-prod` | Credencial de archivo | kubeconfig de cada clúster k3s, descargado con `deploy/k8s/scripts/get-kubeconfig.sh` (parámetro SSM de US-20) |
| `CG_TF_STATE_BUCKET`, `CG_TF_LOCK_TABLE`, `CG_AWS_REGION` | Variables globales (opcionales) | Backend de Terraform. Por defecto `circleguard-terraform-state-<cuenta>`, `circleguard-terraform-locks` y `us-east-2` |
| `CG_DEPLOY_PLATFORM` | Variable global (opcional) | `compose` o `k8s` |

La imagen de Jenkins ([`infra/bootstrap/jenkins/Dockerfile`](../../infra/bootstrap/jenkins/Dockerfile)) instala Terraform 1.11.4, Trivy 0.58.1 (con las plantillas JUnit y HTML) y kubectl v1.32.2, cada uno comparado contra el checksum del proveedor. Hay que reconstruirla en el servidor de CI para que las etapas nuevas funcionen:

```bash
sudo bash /opt/circleguard-ci/infra/bootstrap/bootstrap-ci.sh --mode jenkins --public-host 18.117.90.15
```

## Pruebas

| Comando | Qué cubre |
| :--- | :--- |
| `bash jenkins/test/run-platform-validation.sh` | Plan de etapas, compuerta de apply por ambiente, plataforma de despliegue, rollback, cableado y orden del Jenkinsfile, herramientas de la imagen |
| `bash infra/scripts/test-platform-scripts.sh` | `tf-pipeline.sh`, `trivy-scan.sh` y `k8s-deploy.sh` con binarios simulados (incluye un render real con `kubectl kustomize` si está instalado) |
| `bash jenkins/test/run-multibranch-validation.sh` | Las 22 validaciones previas de US-13, US-30 y US-31 siguen pasando |

`test-platform-scripts.sh` y `test-rollback.sh` también corren en la etapa `Validate Compose Environments`, así que un PR que rompa estos scripts falla en CI.

## Pendiente para cerrar las historias

- Reconstruir la imagen de Jenkins y crear las credenciales `aws-terraform` y `kubeconfig-<env>`.
- Primera ejecución real: plan archivado de un PR de Terraform, un apply en prod con aprobación y un despliegue k8s de dev a stage. Las capturas van en `docs/informe/capturas/`.
- Triage del primer escaneo real de Trivy. Las excepciones que se acepten se agregan a `.trivyignore` con su justificación.
- US-39 depende de los manifiestos de los 8 servicios en `deploy/k8s` (US-21 / US-37). La rama de US-21 tiene hoy el namespace y el middleware.
