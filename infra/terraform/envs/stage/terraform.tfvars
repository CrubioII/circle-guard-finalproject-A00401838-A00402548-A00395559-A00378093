# Parámetros de stage: réplica cercana a prod. Los tags son inmutables para que la
# versión validada aquí sea la misma que se promueve a prod.
# Este archivo no contiene secretos ni credenciales.
environment = "stage"
aws_region  = "us-east-2"

# Red (VPC) — US-20
network_vpc_cidr         = "10.20.0.0/16"
network_az_count         = 2
network_enable_flow_logs = false

# Cómputo (clúster k3s de un nodo) — US-20
compute_server_instance_type          = "m7i-flex.large"
compute_agent_count                   = 0
compute_root_volume_size_gb           = 40
compute_enable_detailed_monitoring    = false
compute_enable_termination_protection = false

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
