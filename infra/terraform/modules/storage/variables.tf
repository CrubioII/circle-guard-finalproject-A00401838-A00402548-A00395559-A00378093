variable "name_prefix" {
  description = "Prefijo de los buckets (proyecto). Los buckets quedan como <name_prefix>-<environment>-<propósito>-<sufijo>."
  type        = string
  default     = "circleguard"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix debe tener entre 2 y 21 caracteres en minúscula: letras, números o guiones."
  }
}

variable "environment" {
  description = "Ambiente al que pertenecen los buckets: dev, stage o prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment debe ser dev, stage o prod."
  }
}

variable "buckets" {
  description = <<-EOT
    Buckets a crear, por propósito (la clave forma parte del nombre). Por cada uno:
      versioning                         - conserva versiones anteriores de los objetos
      noncurrent_version_expiration_days - días que se guardan las versiones anteriores
      transition_to_ia_days              - días hasta pasar a STANDARD_IA (null = nunca, mínimo 30)
      expiration_days                    - días hasta borrar los objetos (null = nunca)
  EOT
  type = map(object({
    versioning                         = optional(bool, true)
    noncurrent_version_expiration_days = optional(number, 30)
    transition_to_ia_days              = optional(number)
    expiration_days                    = optional(number)
  }))
  default = {
    documents = {}
    backups   = {}
  }

  validation {
    condition     = length(var.buckets) > 0 && alltrue([for k in keys(var.buckets) : can(regex("^[a-z0-9][a-z0-9-]{0,14}$", k))])
    error_message = "Cada clave de buckets debe tener 1 a 15 caracteres en minúscula: letras, números o guiones."
  }

  validation {
    condition     = alltrue([for b in values(var.buckets) : b.transition_to_ia_days == null || try(b.transition_to_ia_days >= 30, false)])
    error_message = "transition_to_ia_days debe ser null o al menos 30 (mínimo que exige S3 para STANDARD_IA)."
  }

  validation {
    condition = alltrue([
      for b in values(var.buckets) :
      b.expiration_days == null || b.transition_to_ia_days == null || try(b.expiration_days > b.transition_to_ia_days, false)
    ])
    error_message = "expiration_days debe ser mayor que transition_to_ia_days."
  }

  validation {
    condition     = alltrue([for b in values(var.buckets) : b.noncurrent_version_expiration_days >= 1])
    error_message = "noncurrent_version_expiration_days debe ser al menos 1."
  }
}

variable "bucket_name_suffix" {
  description = "Sufijo para que los nombres sean únicos en todo S3. Con null se usa <id de cuenta>-<región>."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "ARN de una clave KMS propia para SSE-KMS. Con null se usa la clave administrada por AWS (aws/s3)."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Permite borrar los buckets aunque tengan objetos (útil en dev para terraform destroy)."
  type        = bool
  default     = false
}

variable "enable_access_logging" {
  description = "Crea un bucket de logs y registra en él los accesos a cada bucket (auditoría)."
  type        = bool
  default     = false
}

variable "access_log_retention_days" {
  description = "Días que se conservan los logs de acceso."
  type        = number
  default     = 90

  validation {
    condition     = var.access_log_retention_days >= 1
    error_message = "access_log_retention_days debe ser al menos 1."
  }
}

variable "tags" {
  description = "Tags adicionales para todos los recursos del módulo."
  type        = map(string)
  default     = {}
}
