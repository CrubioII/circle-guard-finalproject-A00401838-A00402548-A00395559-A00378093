# US-36 — Backend remoto de Terraform con bloqueo y diagramas de infraestructura

| | |
|---|---|
| Historia | US-36 (3 SP), épico E2.1 — IaC con Terraform. Jira [SCRUM-118](https://circleguard777.atlassian.net/browse/SCRUM-118) |
| Alcance | Bucket S3 para el estado de Terraform, bloqueo del estado, conexión de dev, stage y prod al backend, prueba de concurrencia y diagramas de la infraestructura |
| Fuera de alcance | `apply` de la red, el cómputo y los servicios de US-20 y US-35 |
| Relación | Completa el backend parcial que dejaron [US-20](TERRAFORM_RED_COMPUTO_US20.md) y [US-35](TERRAFORM_PLATAFORMA_US35.md). El `plan` y el `apply` desde Jenkins son de [US-22](PIPELINE_PLATAFORMA_US22_US38_US39.md). |
| Código | [`infra/terraform/bootstrap`](../../infra/terraform/bootstrap/) |

La historia entra en tres PR:

| Parte | Contenido |
|---|---|
| 1 (este documento por ahora) | Stack `bootstrap`: el bucket de estado y sus controles |
| 2 | Scripts del backend, ambientes con `use_lockfile`, `tf-pipeline.sh` de US-22 con el mismo bloqueo y prueba de concurrencia (CA1 y CA2) |
| 3 | Etapa `Validate Terraform` de Jenkins, evidencia de `init`, `validate` y `plan`, y diagramas (CA3) |

## 1. Decisiones

| Decisión | Motivo |
|---|---|
| Un bucket S3 por cuenta (`circleguard-terraform-state-<ID_CUENTA>`) con una clave por raíz | Cada ambiente tiene su estado y su bloqueo: un `apply` en dev no detiene a prod. El ID de cuenta hace el nombre único sin escribirlo en Git. |
| Bloqueo nativo de S3 (`use_lockfile = true`) y no DynamoDB | Terraform 1.10 agregó el bloqueo con escritura condicional en S3 y marcó `dynamodb_table` como obsoleto. Cumple CA1 sin una segunda tabla que mantener ni pagar. El CA menciona DynamoDB solo como ejemplo. |
| Stack `bootstrap` separado de los ambientes | El bucket debe existir antes de que un ambiente pueda usarlo y no debe borrarse con `terraform destroy` de un ambiente. |
| El estado del bootstrap vive en el mismo bucket | Se crea con estado local y luego se migra (`init -migrate-state`). Así ningún estado queda solo en un computador. |
| SSE-S3 (AES256) en vez de SSE-KMS | Quien lee el estado no necesita permisos sobre una clave KMS, y la clave de US-35 es por ambiente, no compartida. |

## 2. Estructura

```
infra/terraform/bootstrap/
├── main.tf                    # bucket y sus 6 controles
├── backend.tf                 # backend "s3" {} parcial: bootstrap/terraform.tfstate
├── backend.hcl.example
├── variables.tf · outputs.tf · providers.tf · versions.tf
├── .terraform.lock.hcl        # proveedor AWS 6.73.0, igual que los ambientes
└── tests/bootstrap.tftest.hcl # plan simulado, sin credenciales
```

### Bucket de estado

| Control | Recurso | Valor |
|---|---|---|
| Versionado | `aws_s3_bucket_versioning` | `Enabled`: cada escritura del estado deja una versión recuperable |
| Cifrado | `aws_s3_bucket_server_side_encryption_configuration` | SSE-S3 (`AES256`) con bucket key |
| Sin acceso público | `aws_s3_bucket_public_access_block` | Los cuatro bloqueos activos |
| Sin ACL | `aws_s3_bucket_ownership_controls` | `BucketOwnerEnforced` |
| Solo TLS | `aws_s3_bucket_policy` | Rechaza `aws:SecureTransport = false` y TLS menor a 1.2; rechaza subidas con otro cifrado |
| Ciclo de vida | `aws_s3_bucket_lifecycle_configuration` | Versiones anteriores: 90 días, siempre se conservan las 10 más nuevas; marcadores de borrado sueltos se limpian; multipart incompleto a 7 días |
| Protección | `lifecycle.prevent_destroy` y `force_destroy = false` | Terraform se niega a destruir el bucket y S3 no lo borra con objetos |

### Permisos de quien ejecuta Terraform

El usuario IAM `circleguard-terraform` se creó a mano en la consola, fuera de Terraform, y sus llaves quedan en `~/.aws` con el perfil del mismo nombre.

- `ReadOnlyAccess` (política administrada): `terraform plan` de los tres ambientes.
- Política inline `CircleGuardTerraformState`: `s3:*` solo sobre `arn:aws:s3:::circleguard-terraform-state-*` y sus objetos.

Con estos permisos el usuario no puede crear VPC, instancias ni roles. Para el `apply` de los ambientes hace falta otro perfil con más permisos.

## 3. Estado en la cuenta del proyecto

El bucket ya existe en `us-east-2` (creado el 2026-11-21 con este stack) y guarda solo `bootstrap/terraform.tfstate`. Con el código de este PR:

```
$ cd infra/terraform/bootstrap
$ terraform init -backend-config=backend.hcl     # backend.hcl: copia de backend.hcl.example con el ID de la cuenta
$ terraform test
tests/bootstrap.tftest.hcl... pass
Success! 2 passed, 0 failed.

$ AWS_PROFILE=circleguard-terraform terraform plan -lock=false
No changes. Your infrastructure matches the configuration.
```

| Comprobación | Resultado |
|---|---|
| `get-bucket-versioning` | `Enabled` |
| Objetos del bucket | `bootstrap/terraform.tfstate` |
| Tabla DynamoDB `circleguard-terraform-locks` | No existe: el bloqueo será el nativo de S3 |

`terraform test` usa un proveedor simulado y no necesita credenciales. El script que crea el bucket la primera vez y migra su estado (`bootstrap-backend.sh`) llega en la parte 2.

## 4. Costo

El bucket guarda unos pocos archivos de menos de 1 MB. El costo esperado es menor a 0,10 USD al mes, sumando almacenamiento y peticiones. No hay tabla DynamoDB.
