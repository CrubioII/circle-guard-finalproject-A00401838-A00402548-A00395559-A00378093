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
  description = "Ambiente al que pertenece la red: dev, stage o prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment debe ser dev, stage o prod."
  }
}

variable "vpc_cidr" {
  description = "Rango IPv4 de la VPC, entre /16 y /20. Usa rangos distintos por ambiente para poder conectarlos (peering) sin solaparse."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr debe ser un CIDR IPv4 válido entre /16 y /20, por ejemplo 10.10.0.0/16."
  }
}

variable "az_count" {
  description = "Zonas de disponibilidad que usa la red. Cada zona tiene una subred pública y una privada."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_count debe estar entre 1 y 3."
  }
}

variable "subnet_newbits" {
  description = "Bits que se agregan a la máscara de la VPC para cada subred. Con una VPC /16 y 8 bits, cada subred es /24 (251 IPs útiles)."
  type        = number
  default     = 8

  validation {
    # Las subredes privadas empiezan en el índice 10, así que se necesitan al menos 4 bits.
    condition     = var.subnet_newbits >= 4 && var.subnet_newbits <= 12
    error_message = "subnet_newbits debe estar entre 4 y 12."
  }
}

variable "enable_nat_gateway" {
  description = "Crea NAT Gateway para que las subredes privadas salgan a internet. Cuesta unos 32 USD al mes por NAT, más el tráfico."
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "Con NAT activo: true crea un solo NAT para todas las zonas (más barato); false crea uno por zona (alta disponibilidad)."
  type        = bool
  default     = true
}

variable "enable_s3_endpoint" {
  description = "Crea un endpoint de tipo gateway para S3 (sin costo). El tráfico a S3 y a las capas de imágenes de ECR no sale a internet."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Registra el tráfico aceptado y rechazado de la VPC en CloudWatch Logs (auditoría)."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Días que se conservan los VPC Flow Logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days debe ser uno de los valores que admite CloudWatch Logs (1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}

variable "flow_logs_kms_key_arn" {
  description = "Clave KMS para cifrar el log group de Flow Logs (por ejemplo, la de observability en US-35). Con null se usa el cifrado por defecto de CloudWatch."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags adicionales para todos los recursos del módulo."
  type        = map(string)
  default     = {}
}
