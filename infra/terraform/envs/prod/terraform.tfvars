# Parámetros de prod: tags inmutables, sin borrado forzado, mayor retención,
# logs de acceso para auditoría y umbral de alarma más estricto.
# Este archivo no contiene secretos ni credenciales.
environment = "prod"
aws_region  = "us-east-2"

# Red (VPC) — US-20: Flow Logs para auditoría del tráfico.
network_vpc_cidr                 = "10.30.0.0/16"
network_az_count                 = 2
network_enable_flow_logs         = true
network_flow_logs_retention_days = 90

# Cómputo (clúster k3s) — US-20. Un nodo para respetar la cuota de 8 vCPU;
# subir compute_agent_count agrega capacidad sin cambiar el código.
compute_server_instance_type          = "m7i-flex.large"
compute_agent_count                   = 0
compute_root_volume_size_gb           = 50
compute_enable_detailed_monitoring    = true
compute_enable_termination_protection = true

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
