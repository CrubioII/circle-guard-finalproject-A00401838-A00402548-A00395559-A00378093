# Parámetros de dev: retención corta, tags mutables y borrado permitido
# para iterar rápido y poder destruir el ambiente sin pasos manuales.
# Este archivo no contiene secretos ni credenciales.
environment = "dev"
aws_region  = "us-east-2"

# Red (VPC) — US-20
network_vpc_cidr         = "10.10.0.0/16"
network_az_count         = 2
network_enable_flow_logs = false

# Cómputo (clúster k3s de un nodo) — US-20
compute_server_instance_type          = "m7i-flex.large"
compute_agent_count                   = 0
compute_root_volume_size_gb           = 30
compute_enable_detailed_monitoring    = false
compute_enable_termination_protection = false

# Registro (ECR)
registry_image_tag_mutability           = "MUTABLE"
registry_max_image_count                = 10
registry_untagged_image_expiration_days = 3
registry_force_delete                   = true

# Almacenamiento (S3)
storage_buckets = {
  documents = {
    versioning                         = true
    noncurrent_version_expiration_days = 7
  }
  backups = {
    versioning                         = false
    noncurrent_version_expiration_days = 1
    expiration_days                    = 14
  }
}
storage_force_destroy         = true
storage_enable_access_logging = false

# Observabilidad (CloudWatch + SNS)
observability_log_retention_days           = 7
observability_error_alarm_threshold        = 20
observability_kms_key_deletion_window_days = 7
