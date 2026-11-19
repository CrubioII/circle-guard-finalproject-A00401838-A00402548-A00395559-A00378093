# Infraestructura como código — Terraform

Infraestructura de CircleGuard en AWS (`us-east-2`) declarada con Terraform. Hay módulos reutilizables y una raíz por ambiente.

| Carpeta | Contenido |
|---|---|
| [`modules/registry`](modules/registry/README.md) | Amazon ECR: repositorio por servicio (US-35) |
| [`modules/storage`](modules/storage/README.md) | Amazon S3: documentos y backups (US-35) |
| [`modules/observability`](modules/observability/README.md) | CloudWatch Logs, alarmas, SNS y dashboard (US-35) |
| `envs/dev`, `envs/stage`, `envs/prod` | Raíz por ambiente. El código es el mismo y solo cambia `terraform.tfvars` |
| [`scripts/plan-all.sh`](scripts/plan-all.sh) | Formato, validación, pruebas, planes y búsqueda de credenciales |

Requisitos: Terraform 1.11 o superior. Para validar y probar no hacen falta credenciales AWS.

```bash
bash infra/terraform/scripts/plan-all.sh                    # sin credenciales
bash infra/terraform/scripts/plan-all.sh --real --env dev   # plan real (AWS_PROFILE + backend.hcl)
```

Diseño, parámetros por ambiente y criterios de aceptación: [`docs/arquitectura/TERRAFORM_PLATAFORMA_US35.md`](../../docs/arquitectura/TERRAFORM_PLATAFORMA_US35.md).
