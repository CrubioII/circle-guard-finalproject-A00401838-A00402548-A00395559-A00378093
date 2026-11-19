# Infraestructura del ambiente. Los tres ambientes usan este mismo código y solo
# cambian sus terraform.tfvars.
#   US-20: red (VPC) y cómputo (clúster k3s)
#   US-35: registro (ECR), almacenamiento (S3) y observabilidad (CloudWatch + SNS)

module "network" {
  source = "../../modules/network"

  name_prefix              = var.project
  environment              = var.environment
  vpc_cidr                 = var.network_vpc_cidr
  az_count                 = var.network_az_count
  enable_nat_gateway       = var.network_enable_nat_gateway
  enable_flow_logs         = var.network_enable_flow_logs
  flow_logs_retention_days = var.network_flow_logs_retention_days
  # La clave de observability ya autoriza a CloudWatch Logs bajo /circleguard/<env>/*.
  flow_logs_kms_key_arn = module.observability.kms_key_arn
}

module "compute" {
  source = "../../modules/compute"

  name_prefix = var.project
  environment = var.environment

  # Sin NAT, los nodos viven en las subredes públicas: el server sale por su IP
  # elástica y los agents por su IP pública. Solo se exponen 80/443 y la API a la VPC.
  vpc_id     = module.network.vpc_id
  vpc_cidr   = module.network.vpc_cidr
  subnet_ids = module.network.public_subnet_ids

  server_instance_type          = var.compute_server_instance_type
  agent_count                   = var.compute_agent_count
  root_volume_size_gb           = var.compute_root_volume_size_gb
  k3s_version                   = var.compute_k3s_version
  api_allowed_cidrs             = var.compute_api_allowed_cidrs
  ingress_allowed_cidrs         = var.compute_ingress_allowed_cidrs
  enable_detailed_monitoring    = var.compute_enable_detailed_monitoring
  enable_termination_protection = var.compute_enable_termination_protection
}

module "registry" {
  source = "../../modules/registry"

  name_prefix                    = var.project
  environment                    = var.environment
  repositories                   = var.services
  image_tag_mutability           = var.registry_image_tag_mutability
  max_image_count                = var.registry_max_image_count
  untagged_image_expiration_days = var.registry_untagged_image_expiration_days
  force_delete                   = var.registry_force_delete
  pull_principal_arns            = var.registry_pull_principal_arns
}

module "storage" {
  source = "../../modules/storage"

  name_prefix           = var.project
  environment           = var.environment
  buckets               = var.storage_buckets
  force_destroy         = var.storage_force_destroy
  enable_access_logging = var.storage_enable_access_logging
}

module "observability" {
  source = "../../modules/observability"

  name_prefix                  = var.project
  environment                  = var.environment
  services                     = var.services
  log_retention_days           = var.observability_log_retention_days
  error_alarm_threshold        = var.observability_error_alarm_threshold
  kms_key_deletion_window_days = var.observability_kms_key_deletion_window_days
  alarm_email_endpoints        = var.observability_alarm_email_endpoints
}
