output "environment" {
  description = "Ambiente desplegado."
  value       = var.environment
}

# -----------------------------------------------------------------------------
# Registro
# -----------------------------------------------------------------------------

output "registry_url" {
  description = "Host del registro ECR para docker login."
  value       = module.registry.registry_url
}

output "registry_repository_names" {
  description = "Repositorio ECR de cada servicio."
  value       = module.registry.repository_names
}

output "registry_repository_urls" {
  description = "URL de cada repositorio ECR, por servicio."
  value       = module.registry.repository_urls
}

output "registry_image_tag_mutability" {
  description = "Mutabilidad de tags del ambiente."
  value       = module.registry.image_tag_mutability
}

# -----------------------------------------------------------------------------
# Almacenamiento
# -----------------------------------------------------------------------------

output "storage_bucket_names" {
  description = "Bucket S3 de cada propósito."
  value       = module.storage.bucket_names
}

output "storage_bucket_arns" {
  description = "ARN de cada bucket S3."
  value       = module.storage.bucket_arns
}

output "storage_access_log_bucket_name" {
  description = "Bucket de logs de acceso, o null."
  value       = module.storage.access_log_bucket_name
}

output "storage_versioning_enabled" {
  description = "Si el versionado está activo, por propósito."
  value       = module.storage.versioning_enabled
}

output "storage_read_write_policy_json" {
  description = "Política IAM de lectura y escritura por bucket, para el rol de file-service."
  value       = module.storage.read_write_policy_json
}

# -----------------------------------------------------------------------------
# Observabilidad
# -----------------------------------------------------------------------------

output "observability_log_group_names" {
  description = "Log group de cada servicio."
  value       = module.observability.log_group_names
}

output "observability_log_retention_days" {
  description = "Retención de logs del ambiente."
  value       = module.observability.log_retention_days
}

output "observability_alarm_names" {
  description = "Alarma de errores de cada servicio."
  value       = module.observability.alarm_names
}

output "observability_alerts_topic_arn" {
  description = "Topic SNS de alertas."
  value       = module.observability.alerts_topic_arn
}

output "observability_kms_key_arn" {
  description = "Clave KMS de logs y alertas."
  value       = module.observability.kms_key_arn
}

output "observability_metric_namespace" {
  description = "Namespace de las métricas de errores."
  value       = module.observability.metric_namespace
}

output "observability_dashboard_name" {
  description = "Dashboard de CloudWatch del ambiente."
  value       = module.observability.dashboard_name
}
