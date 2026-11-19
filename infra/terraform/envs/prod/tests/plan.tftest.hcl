# Plan del ambiente prod con proveedor simulado y los valores de terraform.tfvars.
# No necesita credenciales AWS ni backend remoto:
#   cd infra/terraform/envs/prod && terraform init -backend=false && terraform test

mock_provider "aws" {
  # Los valores simulados se usan ya en el plan (Terraform >= 1.11).
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

run "plan_prod" {
  command = plan

  assert {
    condition     = output.environment == "prod"
    error_message = "terraform.tfvars debe declarar environment = \"prod\"."
  }

  assert {
    condition     = length(output.registry_repository_names) == 9
    error_message = "Debe existir un repositorio ECR por cada uno de los 8 servicios y el cliente web."
  }

  assert {
    condition     = output.registry_repository_names["auth-service"] == "circleguard/prod/auth-service"
    error_message = "Los repositorios de prod deben llevar el prefijo circleguard/prod/."
  }

  assert {
    condition     = output.registry_image_tag_mutability == "IMMUTABLE"
    error_message = "En prod los tags deben ser IMMUTABLE."
  }

  assert {
    condition     = output.storage_bucket_names["documents"] == "circleguard-prod-documents-123456789012-us-east-2"
    error_message = "El bucket de documentos debe pertenecer a prod."
  }

  assert {
    condition     = output.storage_access_log_bucket_name == "circleguard-prod-access-logs-123456789012-us-east-2"
    error_message = "En prod debe existir el bucket de logs de acceso."
  }

  assert {
    condition     = length(output.observability_log_group_names) == 9 && output.observability_log_group_names["form-service"] == "/circleguard/prod/form-service"
    error_message = "Debe existir un log group por servicio bajo /circleguard/prod/."
  }

  assert {
    condition     = output.observability_log_retention_days == 30
    error_message = "En prod la retención de logs debe ser 30 días."
  }

  assert {
    condition     = length(output.observability_alarm_names) == 9
    error_message = "Debe existir una alarma de errores por servicio."
  }

  assert {
    condition     = output.observability_metric_namespace == "CircleGuard/prod"
    error_message = "Las métricas de prod deben publicarse en CircleGuard/prod."
  }
}
