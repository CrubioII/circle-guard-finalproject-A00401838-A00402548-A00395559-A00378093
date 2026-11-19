variable "name_prefix" {
  description = "Prefijo de los recursos (proyecto)."
  type        = string
  default     = "circleguard"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix debe tener entre 2 y 31 caracteres en minúscula: letras, números o guiones."
  }
}

variable "environment" {
  description = "Ambiente al que pertenecen los recursos: dev, stage o prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment debe ser dev, stage o prod."
  }
}

variable "services" {
  description = "Servicios que tendrán log group, filtro de errores y alarma. El log group queda como /<name_prefix>/<environment>/<servicio>."
  type        = list(string)

  validation {
    condition     = length(var.services) > 0 && alltrue([for s in var.services : can(regex("^[a-z0-9][a-z0-9-]*$", s))])
    error_message = "services debe tener al menos un nombre en minúscula (letras, números o guiones)."
  }

  validation {
    condition     = length(var.services) == length(distinct(var.services))
    error_message = "services no puede tener nombres repetidos."
  }
}

variable "log_retention_days" {
  description = "Días que CloudWatch conserva los logs de cada servicio."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days debe ser uno de los valores que admite CloudWatch Logs (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, ...)."
  }
}

variable "kms_key_deletion_window_days" {
  description = "Días de espera antes de borrar la clave KMS de observabilidad tras un destroy."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days debe estar entre 7 y 30."
  }
}

variable "error_log_pattern" {
  description = "Patrón de filtro de CloudWatch Logs que cuenta una línea como error."
  type        = string
  default     = "?ERROR ?Exception"
}

variable "error_alarm_threshold" {
  description = "Errores por periodo a partir de los cuales se dispara la alarma de un servicio."
  type        = number
  default     = 10

  validation {
    condition     = var.error_alarm_threshold >= 1
    error_message = "error_alarm_threshold debe ser al menos 1."
  }
}

variable "error_alarm_period_seconds" {
  description = "Duración en segundos de cada periodo que evalúa la alarma."
  type        = number
  default     = 300

  validation {
    condition     = contains([60, 300, 900, 3600], var.error_alarm_period_seconds)
    error_message = "error_alarm_period_seconds debe ser 60, 300, 900 o 3600."
  }
}

variable "error_alarm_evaluation_periods" {
  description = "Periodos consecutivos sobre el umbral necesarios para disparar la alarma."
  type        = number
  default     = 1

  validation {
    condition     = var.error_alarm_evaluation_periods >= 1
    error_message = "error_alarm_evaluation_periods debe ser al menos 1."
  }
}

variable "alarm_email_endpoints" {
  description = "Correos suscritos al topic de alertas. Cada uno debe confirmar la suscripción. Conviene pasarlos con TF_VAR_alarm_email_endpoints en vez de versionarlos."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alarm_email_endpoints : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Cada valor de alarm_email_endpoints debe ser un correo válido."
  }
}

variable "enable_dashboard" {
  description = "Crea un dashboard de CloudWatch con los errores por servicio."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags adicionales para todos los recursos del módulo."
  type        = map(string)
  default     = {}
}
