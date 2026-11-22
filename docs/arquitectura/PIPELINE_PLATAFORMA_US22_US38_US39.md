# Pipeline de plataforma: Terraform, Trivy y Kubernetes (US-22, US-38, US-39)

Épica EPIC-11 (pipeline incrementado, entregable E2.3). Responsable: Juan Camilo Rubio.

El Jenkinsfile de la Parte 1 compilaba, probaba, publicaba en Nexus y desplegaba con Docker Compose por SSH. En la Parte 2 se le agregan tres cosas: Terraform con aprobación antes de prod, un escaneo de Trivy que corta el build y una segunda plataforma de despliegue, Kubernetes, que reutiliza las mismas compuertas de dev, stage y prod.

La decisión de qué etapas corren vive en [`jenkins/vars/platformFlow.groovy`](../../jenkins/vars/platformFlow.groovy). El Jenkinsfile lo carga desde el workspace con `load` (igual que `sonarQualityGate`), así cada rama prueba su propia versión. La lógica se valida sin Jenkins con `bash jenkins/test/run-platform-validation.sh`.

## Flujo en main

```
Detect -> Compile/Test -> Sonar -> Validate Compose (+ pruebas de scripts de plataforma)
       -> Terraform Plan (dev, stage, prod)        solo si cambia infra/terraform
       -> Publish Images to Nexus
       -> Terraform Apply dev -> Deploy to dev -> Verify dev -> E2E against dev
       -> Terraform Apply stage -> Promote to stage -> Verify stage
       -> Approve prod release (US-31) -> Terraform Apply prod -> Deploy to prod -> Verify prod
```
En un Pull Request solo corre `Terraform Plan`, si el PR toca Terraform. Un PR nunca aplica Terraform ni despliega.

## US-22: Terraform en Jenkins

| Criterio | Cómo se cumple |
| :--- | :--- |
| CA1: `plan` en cada PR que modifique `infra/terraform/`, archivado | `platformFlow.planPlatform` marca `runTerraformPlan` cuando cambia un `.tf`, `.tfvars`, `.hcl` o script de `infra/terraform` (un README no cuenta). La etapa `Terraform Plan` corre [`tf-pipeline.sh plan`](../../infra/terraform/scripts/tf-pipeline.sh) para los tres ambientes y archiva `reports/terraform/<env>-plan.txt`, `-plan.json` y `-summary.json` |
| CA2: `apply` automático en dev y stage; prod espera el `input` de US-31 | `Terraform Apply dev` corre antes de desplegar dev. `Terraform Apply stage` exige que dev haya pasado despliegue, healthchecks y E2E. `Terraform Apply prod` va después de `Approve prod release` y solo corre si `prodApproval.deploy == true`, es decir, con los aprobadores de `CG_PROD_APPROVERS` |

`apply` aplica el archivo `reports/terraform/<env>.tfplan` que generó `plan` en la misma ejecución. Si no existe, el script sale con código 3: no se aplica nada que no se haya planificado y archivado. El resultado por ambiente queda en `reports/ci/terraform-apply.json`.

El backend es el de US-20 (S3 + DynamoDB en la Región del proyecto). `tf-pipeline.sh` arma la configuración al iniciar, sin datos de la cuenta en Git: el bucket sale de `CG_TF_STATE_BUCKET` o, si está vacío, de `circleguard-terraform-state-<ID_CUENTA>` con `aws sts get-caller-identity`.

`FORCE_TERRAFORM=true` corre plan (y apply en main) aunque el commit no toque Terraform, por ejemplo para detectar drift.

## Configuración en Jenkins

| Elemento | Tipo | Uso |
| :--- | :--- | :--- |
| `aws-terraform` | Credencial usuario/contraseña (Access Key ID / Secret) | Terraform plan y apply. Debe ser una identidad con permisos solo sobre los recursos de CircleGuard |
| `CG_TF_STATE_BUCKET`, `CG_TF_LOCK_TABLE`, `CG_AWS_REGION` | Variables globales (opcionales) | Backend de Terraform. Por defecto `circleguard-terraform-state-<cuenta>`, `circleguard-terraform-locks` y `us-east-2` |

La imagen de Jenkins ([`infra/bootstrap/jenkins/Dockerfile`](../../infra/bootstrap/jenkins/Dockerfile)) instala Terraform 1.11.4, comparado contra el checksum del proveedor. Hay que reconstruirla en el servidor de CI para que las etapas nuevas funcionen:

```bash
sudo bash /opt/circleguard-ci/infra/bootstrap/bootstrap-ci.sh --mode jenkins --public-host 18.117.90.15
```

## Pruebas

| Comando | Qué cubre |
| :--- | :--- |
| `bash jenkins/test/run-platform-validation.sh` | Plan de etapas, compuerta de apply por ambiente, cableado y orden del Jenkinsfile, Terraform en la imagen |
| `bash infra/scripts/test-platform-scripts.sh` | `tf-pipeline.sh` con un terraform simulado |
| `bash jenkins/test/run-multibranch-validation.sh` | Las 22 validaciones previas de US-13, US-30 y US-31 siguen pasando |

`test-platform-scripts.sh` también corre en la etapa `Validate Compose Environments`, así que un PR que rompa estos scripts falla en CI.

## Pendiente para cerrar las historias

- Reconstruir la imagen de Jenkins y crear la credencial `aws-terraform`.
- Primera ejecución real: plan archivado de un PR de Terraform y un apply en prod con aprobación. Las capturas van en `docs/informe/capturas/`.
