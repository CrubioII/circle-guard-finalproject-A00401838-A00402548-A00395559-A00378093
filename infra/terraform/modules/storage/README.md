# Módulo `storage` — Amazon S3

Crea buckets privados por propósito, con este formato de nombre: `<name_prefix>-<environment>-<propósito>-<sufijo>`, por ejemplo `circleguard-prod-documents-123456789012-us-east-2`. Por defecto el sufijo es `<id de cuenta>-<región>`, para que el nombre sea único en todo S3.

Está pensado para los documentos y certificados de `file-service`, que hoy usa un placeholder S3/MinIO, y para backups.

Cada bucket:

- bloquea todo acceso público y deshabilita las ACL (`BucketOwnerEnforced`);
- cifra con SSE-KMS (clave `aws/s3` o una propia), con *bucket key* para reducir costo;
- rechaza conexiones sin TLS o con TLS menor a 1.2;
- versiona los objetos, o suspende el versionado si se pide;
- aplica un ciclo de vida: aborta subidas multipart incompletas, expira versiones anteriores y, de forma opcional, pasa los objetos a `STANDARD_IA` y los expira;
- opcionalmente registra sus accesos en un bucket de logs propio (auditoría).

Además, el módulo entrega una política IAM de lectura y escritura por bucket para adjuntarla al rol del servicio. Así el servicio no necesita *access keys*.

## Uso

```hcl
module "storage" {
  source = "../../modules/storage"

  environment           = "prod"
  enable_access_logging = true
  buckets = {
    documents = { transition_to_ia_days = 90 }
    backups   = { transition_to_ia_days = 30, expiration_days = 365 }
  }
}
```

## Entradas

| Nombre | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `environment` | `string` | — (obligatoria) | `dev`, `stage` o `prod`. |
| `buckets` | `map(object)` | `{ documents = {}, backups = {} }` | Buckets por propósito. Campos: `versioning` (`true`), `noncurrent_version_expiration_days` (`30`), `transition_to_ia_days` (`null`, mínimo 30), `expiration_days` (`null`, mayor que la transición). |
| `name_prefix` | `string` | `"circleguard"` | Prefijo del nombre. |
| `bucket_name_suffix` | `string` | `null` | Sufijo de unicidad. Con `null` se usa `<cuenta>-<región>`. |
| `kms_key_arn` | `string` | `null` | Clave KMS propia. Con `null` se usa `aws/s3`. |
| `force_destroy` | `bool` | `false` | Permite borrar buckets con objetos. |
| `enable_access_logging` | `bool` | `false` | Crea el bucket de logs de acceso y lo conecta. |
| `access_log_retention_days` | `number` | `90` | Días de retención de los logs de acceso. |
| `tags` | `map(string)` | `{}` | Tags adicionales. |

## Salidas

| Nombre | Descripción |
|---|---|
| `bucket_names` | Nombre de cada bucket, por propósito. |
| `bucket_arns` | ARN de cada bucket, por propósito. |
| `bucket_regional_domain_names` | Endpoint regional de cada bucket. |
| `access_log_bucket_name` | Bucket de logs de acceso, o `null`. |
| `kms_key_arn` | Clave KMS usada, o `null` si es `aws/s3`. |
| `read_write_policy_json` | Política IAM (JSON) de lectura y escritura por bucket. |
| `versioning_enabled` | Si el versionado está activo, por propósito. |

## Notas

- El bucket de logs usa SSE-S3 (`AES256`), porque la entrega de logs de acceso de S3 no admite SSE-KMS.
- Con `force_destroy = false` (prod), `terraform destroy` falla si el bucket tiene objetos. Hay que vaciarlo antes o cambiar la variable de forma explícita.

## Pruebas

```bash
cd infra/terraform/modules/storage
terraform init -backend=false
terraform test   # proveedor simulado, sin credenciales
```
