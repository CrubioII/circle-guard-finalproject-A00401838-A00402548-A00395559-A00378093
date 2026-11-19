# Parámetros de prod: tags inmutables, sin borrado forzado, mayor retención,
# logs de acceso para auditoría y umbral de alarma más estricto.
# Este archivo no contiene secretos ni credenciales.
environment = "prod"
aws_region  = "us-east-2"

# Registro (ECR)
registry_image_tag_mutability           = "IMMUTABLE"
registry_max_image_count                = 30
registry_untagged_image_expiration_days = 7
registry_force_delete                   = false

# Almacenamiento (S3)
storage_buckets = {
  documents = {
    versioning                         = true
    noncurrent_version_expiration_days = 30
    transition_to_ia_days              = 90
  }
  backups = {
    versioning                         = true
    noncurrent_version_expiration_days = 30
    transition_to_ia_days              = 30
    expiration_days                    = 365
  }
}
storage_force_destroy         = false
storage_enable_access_logging = true

# Observabilidad (CloudWatch + SNS)
observability_log_retention_days           = 30
observability_error_alarm_threshold        = 5
observability_kms_key_deletion_window_days = 30
