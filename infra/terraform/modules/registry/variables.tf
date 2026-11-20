variable "name_prefix" {
  description = "Prefijo de los repositorios (proyecto). Los repositorios quedan como <name_prefix>/<environment>/<repositorio>."
  type        = string
  default     = "circleguard"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix debe tener entre 2 y 31 caracteres en minúscula: letras, números o guiones."
  }
}

variable "environment" {
  description = "Ambiente al que pertenecen los repositorios: dev, stage o prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment debe ser dev, stage o prod."
  }
}

variable "repositories" {
  description = "Nombres de las imágenes que tendrán repositorio ECR (uno por servicio)."
  type        = list(string)

  validation {
    condition     = length(var.repositories) > 0 && alltrue([for r in var.repositories : can(regex("^[a-z0-9][a-z0-9._-]*$", r))])
    error_message = "repositories debe tener al menos un nombre en minúscula (letras, números, '.', '_' o '-')."
  }

  validation {
    condition     = length(var.repositories) == length(distinct(var.repositories))
    error_message = "repositories no puede tener nombres repetidos."
  }
}

variable "image_tag_mutability" {
  description = "MUTABLE permite sobrescribir un tag. IMMUTABLE lo impide, de modo que una versión promovida no cambia."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability debe ser MUTABLE o IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Escanea vulnerabilidades de cada imagen al subirla."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "ARN de una clave KMS propia para cifrar las imágenes. Con null se usa la clave administrada por AWS (aws/ecr)."
  type        = string
  default     = null
}

variable "max_image_count" {
  description = "Cantidad máxima de imágenes que se conservan por repositorio. Las más antiguas se eliminan."
  type        = number
  default     = 30

  validation {
    condition     = var.max_image_count >= 1 && var.max_image_count <= 1000
    error_message = "max_image_count debe estar entre 1 y 1000."
  }
}

variable "untagged_image_expiration_days" {
  description = "Días tras los cuales se eliminan las imágenes sin tag."
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_image_expiration_days >= 1
    error_message = "untagged_image_expiration_days debe ser al menos 1."
  }
}

variable "force_delete" {
  description = "Permite borrar un repositorio aunque tenga imágenes (útil en dev para terraform destroy)."
  type        = bool
  default     = false
}

variable "pull_principal_arns" {
  description = "ARNs IAM (por ejemplo, el rol de los nodos del clúster) autorizados a descargar imágenes. Vacío no crea política de repositorio."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags adicionales para todos los recursos del módulo."
  type        = map(string)
  default     = {}
}
