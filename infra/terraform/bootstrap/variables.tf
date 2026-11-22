variable "project" {
  description = "Nombre del proyecto. Prefijo del bucket de estado."
  type        = string
  default     = "circleguard"
}

variable "aws_region" {
  description = "Región del bucket de estado. Debe ser la misma de los ambientes."
  type        = string
  default     = "us-east-2"
}

variable "aws_profile" {
  description = "Perfil local de AWS CLI. Con null se usa la cadena de credenciales estándar."
  type        = string
  default     = null
}

variable "noncurrent_version_expiration_days" {
  description = "Días que se conservan las versiones anteriores de cada estado antes de borrarse."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 30
    error_message = "Conserva al menos 30 días de versiones anteriores del estado."
  }
}

variable "noncurrent_versions_to_keep" {
  description = "Versiones anteriores de cada estado que nunca se borran, aunque superen el plazo."
  type        = number
  default     = 10

  validation {
    condition     = var.noncurrent_versions_to_keep >= 1 && var.noncurrent_versions_to_keep <= 100
    error_message = "noncurrent_versions_to_keep debe estar entre 1 y 100."
  }
}
