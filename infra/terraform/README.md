# Infraestructura como código — Terraform

Infraestructura de CircleGuard en AWS (`us-east-2`) declarada con Terraform. Hay módulos reutilizables y una raíz por ambiente.

| Carpeta | Contenido |
|---|---|
| [`modules/network`](modules/network/README.md) | Amazon VPC: subredes por zona, IGW, NAT opcional, endpoint S3 y Flow Logs (US-20) |
| [`modules/compute`](modules/compute/README.md) | Clúster k3s sobre EC2: server con IP elástica y agents opcionales (US-20) |
| [`modules/registry`](modules/registry/README.md) | Amazon ECR: repositorio por servicio (US-35) |
| [`modules/storage`](modules/storage/README.md) | Amazon S3: documentos y backups (US-35) |
| [`modules/observability`](modules/observability/README.md) | CloudWatch Logs, alarmas, SNS y dashboard (US-35) |
| [`bootstrap`](bootstrap/) | Bucket S3 del estado remoto, con versionado, cifrado y bloqueo nativo (US-36) |
| `envs/dev`, `envs/stage`, `envs/prod` | Raíz por ambiente. El código es el mismo y solo cambia `terraform.tfvars` |
| [`scripts/plan-all.sh`](scripts/plan-all.sh) | Formato, validación, pruebas, planes y búsqueda de credenciales |
| [`scripts/bootstrap-backend.sh`](scripts/bootstrap-backend.sh) | Crea el bucket de estado y migra su propio estado a S3 (US-36) |
| [`scripts/init-backend.sh`](scripts/init-backend.sh) | Genera `backend.hcl` en cada raíz con el ID de la cuenta (US-36) |
| [`scripts/test-state-lock.sh`](scripts/test-state-lock.sh) | Prueba que dos `apply` simultáneos no escriben el mismo estado (US-36) |
| [`scripts/ensure-terraform.sh`](scripts/ensure-terraform.sh) | Usa el Terraform del PATH o descarga la 1.14.6 verificando su SHA-256 (etapa `Validate Terraform` de Jenkins) |

Requisitos: Terraform 1.11 o superior. Para validar y probar no hacen falta credenciales AWS.

```bash
bash infra/terraform/scripts/plan-all.sh                    # sin credenciales
export AWS_PROFILE=circleguard-terraform
bash infra/terraform/scripts/init-backend.sh                # backend.hcl de cada raíz (una vez por clon)
bash infra/terraform/scripts/plan-all.sh --real --env dev   # plan real con el backend remoto
bash infra/terraform/scripts/test-state-lock.sh             # prueba del bloqueo
```

Diseño, parámetros por ambiente y criterios de aceptación:

- Red y cómputo: [`docs/arquitectura/TERRAFORM_RED_COMPUTO_US20.md`](../../docs/arquitectura/TERRAFORM_RED_COMPUTO_US20.md)
- Registro, almacenamiento y observabilidad: [`docs/arquitectura/TERRAFORM_PLATAFORMA_US35.md`](../../docs/arquitectura/TERRAFORM_PLATAFORMA_US35.md)
- Estado remoto, bloqueo y diagrama general: [`docs/arquitectura/TERRAFORM_BACKEND_US36.md`](../../docs/arquitectura/TERRAFORM_BACKEND_US36.md)
