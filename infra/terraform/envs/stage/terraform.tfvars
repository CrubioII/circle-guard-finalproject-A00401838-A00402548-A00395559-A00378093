# Parámetros de stage: réplica cercana a prod. Los tags son inmutables para que la
# versión validada aquí sea la misma que se promueve a prod.
# Este archivo no contiene secretos ni credenciales.
environment = "stage"
aws_region  = "us-east-2"

# Registro (ECR)
registry_image_tag_mutability           = "IMMUTABLE"
registry_max_image_count                = 20
registry_untagged_image_expiration_days = 7
registry_force_delete                   = true

# Almacenamiento (S3)
storage_buckets = {
  documents = {
    versioning                         = true
    noncurrent_version_expiration_days = 14
  }
  backups = {
    versioning                         = true
    noncurrent_version_expiration_days = 7
    expiration_days                    = 30
  }
}
storage_force_destroy         = true
storage_enable_access_logging = false

# Observabilidad (CloudWatch + SNS)
observability_log_retention_days           = 14
observability_error_alarm_threshold        = 10
observability_kms_key_deletion_window_days = 7
