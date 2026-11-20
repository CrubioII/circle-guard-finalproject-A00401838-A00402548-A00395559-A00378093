# Plataforma compartida del ambiente: registro, almacenamiento y observabilidad (US-35).
# Los tres ambientes usan este mismo código. Solo cambian sus terraform.tfvars.

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
