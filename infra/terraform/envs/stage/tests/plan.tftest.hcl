# Plan del ambiente stage con proveedor simulado y los valores de terraform.tfvars.
# No necesita credenciales AWS ni backend remoto:
#   cd infra/terraform/envs/stage && terraform init -backend=false && terraform test

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

run "plan_stage" {
  command = plan

  assert {
    condition     = output.environment == "stage"
    error_message = "terraform.tfvars debe declarar environment = \"stage\"."
  }

  assert {
    condition     = length(output.registry_repository_names) == 9
    error_message = "Debe existir un repositorio ECR por cada uno de los 8 servicios y el cliente web."
  }

  assert {
    condition     = output.registry_repository_names["auth-service"] == "circleguard/stage/auth-service"
    error_message = "Los repositorios de stage deben llevar el prefijo circleguard/stage/."
  }

  assert {
    condition     = output.registry_image_tag_mutability == "IMMUTABLE"
    error_message = "En stage los tags deben ser IMMUTABLE."
  }

  assert {
    condition     = output.storage_bucket_names["documents"] == "circleguard-stage-documents-123456789012-us-east-2"
    error_message = "El bucket de documentos debe pertenecer a stage."
  }

  assert {
    condition     = output.storage_access_log_bucket_name == null
    error_message = "En stage no debe crearse bucket de logs de acceso."
  }

  assert {
    condition     = length(output.observability_log_group_names) == 9 && output.observability_log_group_names["form-service"] == "/circleguard/stage/form-service"
    error_message = "Debe existir un log group por servicio bajo /circleguard/stage/."
  }

  assert {
    condition     = output.observability_log_retention_days == 14
    error_message = "En stage la retención de logs debe ser 14 días."
  }

  assert {
    condition     = length(output.observability_alarm_names) == 9
    error_message = "Debe existir una alarma de errores por servicio."
  }

  assert {
    condition     = output.observability_metric_namespace == "CircleGuard/stage"
    error_message = "Las métricas de stage deben publicarse en CircleGuard/stage."
  }
}
