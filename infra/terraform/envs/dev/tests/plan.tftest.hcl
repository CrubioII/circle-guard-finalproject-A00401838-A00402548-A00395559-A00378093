# Plan del ambiente dev con proveedor simulado y los valores de terraform.tfvars.
# No necesita credenciales AWS ni backend remoto:
#   cd infra/terraform/envs/dev && terraform init -backend=false && terraform test

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

run "plan_dev" {
  command = plan

  assert {
    condition     = output.environment == "dev"
    error_message = "terraform.tfvars debe declarar environment = \"dev\"."
  }

  assert {
    condition     = length(output.registry_repository_names) == 9
    error_message = "Debe existir un repositorio ECR por cada uno de los 8 servicios y el cliente web."
  }

  assert {
    condition     = output.registry_repository_names["auth-service"] == "circleguard/dev/auth-service"
    error_message = "Los repositorios de dev deben llevar el prefijo circleguard/dev/."
  }

  assert {
    condition     = output.registry_image_tag_mutability == "MUTABLE"
    error_message = "En dev los tags deben ser MUTABLE."
  }

  assert {
    condition     = output.storage_bucket_names["documents"] == "circleguard-dev-documents-123456789012-us-east-2"
    error_message = "El bucket de documentos debe pertenecer a dev."
  }

  assert {
    condition     = output.storage_access_log_bucket_name == null
    error_message = "En dev no debe crearse bucket de logs de acceso."
  }

  assert {
    condition     = length(output.observability_log_group_names) == 9 && output.observability_log_group_names["form-service"] == "/circleguard/dev/form-service"
    error_message = "Debe existir un log group por servicio bajo /circleguard/dev/."
  }

  assert {
    condition     = output.observability_log_retention_days == 7
    error_message = "En dev la retención de logs debe ser 7 días."
  }

  assert {
    condition     = length(output.observability_alarm_names) == 9
    error_message = "Debe existir una alarma de errores por servicio."
  }

  assert {
    condition     = output.observability_metric_namespace == "CircleGuard/dev"
    error_message = "Las métricas de dev deben publicarse en CircleGuard/dev."
  }
}
