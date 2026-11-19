# Módulo `registry` — Amazon ECR

Crea un repositorio privado de imágenes por servicio, con este formato de nombre: `<name_prefix>/<environment>/<repositorio>`, por ejemplo `circleguard/prod/auth-service`.

Cada repositorio:

- escanea vulnerabilidades al subir cada imagen (`scan_on_push`);
- cifra las imágenes con KMS (clave `aws/ecr` o una propia);
- aplica una política de ciclo de vida: borra las imágenes sin tag tras N días y conserva solo las últimas N imágenes;
- puede impedir sobrescribir tags (`IMMUTABLE`), para que la versión promovida a prod sea exactamente la validada;
- opcionalmente da permiso de *pull* a roles IAM, por ejemplo el de los nodos del clúster.

## Uso

```hcl
module "registry" {
  source = "../../modules/registry"

  environment          = "prod"
  repositories         = ["auth-service", "gateway-service", "web-client"]
  image_tag_mutability = "IMMUTABLE"
  max_image_count      = 30
}
```

## Entradas

| Nombre | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `environment` | `string` | — (obligatoria) | `dev`, `stage` o `prod`. |
| `repositories` | `list(string)` | — (obligatoria) | Imágenes que tendrán repositorio. Sin repetidos, en minúscula. |
| `name_prefix` | `string` | `"circleguard"` | Prefijo del nombre de los repositorios. |
| `image_tag_mutability` | `string` | `"IMMUTABLE"` | `MUTABLE` o `IMMUTABLE`. |
| `scan_on_push` | `bool` | `true` | Escaneo de vulnerabilidades al subir. |
| `kms_key_arn` | `string` | `null` | Clave KMS propia. Con `null` se usa `aws/ecr`. |
| `max_image_count` | `number` | `30` | Imágenes que se conservan por repositorio (1 a 1000). |
| `untagged_image_expiration_days` | `number` | `7` | Días hasta borrar imágenes sin tag. |
| `force_delete` | `bool` | `false` | Permite borrar repositorios con imágenes. |
| `pull_principal_arns` | `list(string)` | `[]` | ARNs IAM con permiso de *pull*. Vacío no crea política. |
| `tags` | `map(string)` | `{}` | Tags adicionales. |

## Salidas

| Nombre | Descripción |
|---|---|
| `repository_names` | Nombre completo de cada repositorio, por servicio. |
| `repository_urls` | URL de cada repositorio, por servicio. |
| `repository_arns` | ARN de cada repositorio, por servicio (para políticas IAM). |
| `registry_id` | ID de la cuenta dueña del registro. |
| `registry_url` | Host para `docker login` (`<cuenta>.dkr.ecr.<región>.amazonaws.com`). |
| `image_tag_mutability` | Mutabilidad aplicada. |

## Pruebas

```bash
cd infra/terraform/modules/registry
terraform init -backend=false
terraform test   # proveedor simulado, sin credenciales
```
