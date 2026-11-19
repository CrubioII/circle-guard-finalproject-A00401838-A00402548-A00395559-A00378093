output "environment" {
  description = "Ambiente desplegado."
  value       = var.environment
}

# -----------------------------------------------------------------------------
# Red
# -----------------------------------------------------------------------------

output "network_vpc_id" {
  description = "VPC del ambiente."
  value       = module.network.vpc_id
}

output "network_vpc_cidr" {
  description = "Rango de la VPC del ambiente."
  value       = module.network.vpc_cidr
}

output "network_availability_zones" {
  description = "Zonas de disponibilidad de la red."
  value       = module.network.availability_zones
}

output "network_public_subnet_ids" {
  description = "Subredes públicas."
  value       = module.network.public_subnet_ids
}

output "network_private_subnet_ids" {
  description = "Subredes privadas."
  value       = module.network.private_subnet_ids
}

output "network_nat_gateway_count" {
  description = "NAT Gateways del ambiente."
  value       = module.network.nat_gateway_count
}

output "network_flow_logs_log_group_name" {
  description = "Log group de los Flow Logs, o null."
  value       = module.network.flow_logs_log_group_name
}

# -----------------------------------------------------------------------------
# Cómputo
# -----------------------------------------------------------------------------

output "compute_cluster_name" {
  description = "Nombre del clúster k3s."
  value       = module.compute.cluster_name
}

output "compute_k3s_version" {
  description = "Versión de k3s."
  value       = module.compute.k3s_version
}

output "compute_api_endpoint" {
  description = "Endpoint de la API de Kubernetes."
  value       = module.compute.api_endpoint
}

output "compute_server_public_ip" {
  description = "IP elástica del nodo server."
  value       = module.compute.server_public_ip
}

output "compute_server_instance_id" {
  description = "Instancia del nodo server (para SSM Session Manager)."
  value       = module.compute.server_instance_id
}

output "compute_node_count" {
  description = "Cantidad total de nodos."
  value       = module.compute.node_count
}

output "compute_node_role_arn" {
  description = "Rol IAM de los nodos."
  value       = module.compute.node_role_arn
}

output "compute_kubeconfig_parameter_name" {
  description = "Parámetro SSM con el kubeconfig de administración."
  value       = module.compute.kubeconfig_parameter_name
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
