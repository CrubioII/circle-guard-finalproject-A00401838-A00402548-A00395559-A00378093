output "bucket_names" {
  description = "Nombre de cada bucket, por propósito."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "bucket_arns" {
  description = "ARN de cada bucket, por propósito."
  value       = { for k, b in aws_s3_bucket.this : k => b.arn }
}

output "bucket_regional_domain_names" {
  description = "Dominio regional de cada bucket, por propósito (endpoint S3 para los clientes)."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket_regional_domain_name }
}

output "access_log_bucket_name" {
  description = "Nombre del bucket de logs de acceso, o null si enable_access_logging es false."
  value       = try(aws_s3_bucket.access_logs[0].bucket, null)
}

output "kms_key_arn" {
  description = "Clave KMS usada para SSE-KMS, o null si se usa la clave administrada por AWS (aws/s3)."
  value       = var.kms_key_arn
}

output "read_write_policy_json" {
  description = "Documento de política IAM (JSON) de lectura y escritura por bucket, para adjuntar al rol del servicio que lo use."
  value       = local.read_write_policy
}

output "versioning_enabled" {
  description = "Si el versionado está activo, por propósito."
  value       = { for k, b in var.buckets : k => b.versioning }
}
