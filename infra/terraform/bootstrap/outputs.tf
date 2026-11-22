output "state_bucket_name" {
  description = "Bucket S3 de los estados de Terraform."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN del bucket de estado, para políticas IAM de quien ejecuta Terraform."
  value       = aws_s3_bucket.state.arn
}

output "state_region" {
  description = "Región del bucket de estado."
  value       = var.aws_region
}

output "state_keys" {
  description = "Clave de estado de cada raíz de Terraform dentro del bucket."
  value = {
    bootstrap = "bootstrap/terraform.tfstate"
    dev       = "envs/dev/platform.tfstate"
    stage     = "envs/stage/platform.tfstate"
    prod      = "envs/prod/platform.tfstate"
  }
}
