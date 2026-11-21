# Plan del ambiente dev (red, cómputo, registro, almacenamiento y observabilidad)
# con proveedor simulado y los valores de terraform.tfvars.
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

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-2a", "us-east-2b", "us-east-2c"]
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_eip" {
    defaults = {
      public_ip = "203.0.113.10"
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

  # Red y cómputo (US-20)
  assert {
    condition     = output.network_vpc_cidr == "10.10.0.0/16"
    error_message = "La VPC de dev debe usar 10.10.0.0/16."
  }

  assert {
    condition     = length(output.network_public_subnet_ids) == 2 && length(output.network_private_subnet_ids) == 2
    error_message = "La red de dev debe tener subredes públicas y privadas en dos zonas."
  }

  assert {
    condition     = output.network_nat_gateway_count == 0
    error_message = "dev no debe crear NAT Gateway (los nodos salen por IP pública)."
  }

  assert {
    condition     = output.network_flow_logs_log_group_name == null
    error_message = "Los Flow Logs de dev no tienen la configuración esperada."
  }

  assert {
    condition     = output.compute_cluster_name == "circleguard-dev-k3s" && output.compute_node_count == 1
    error_message = "dev debe tener su propio clúster k3s de un nodo."
  }

  assert {
    condition     = output.compute_k3s_version == "v1.37.2+k3s1"
    error_message = "El clúster de dev debe usar la versión fija de k3s."
  }

  assert {
    condition     = output.compute_api_endpoint == "https://203.0.113.10:6443"
    error_message = "La API de dev debe publicarse en la IP elástica del server."
  }

  assert {
    condition     = output.compute_kubeconfig_parameter_name == "/circleguard/dev/k3s/kubeconfig"
    error_message = "El kubeconfig de dev debe quedar en SSM bajo /circleguard/dev/k3s/."
  }
}
