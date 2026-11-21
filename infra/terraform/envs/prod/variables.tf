# -----------------------------------------------------------------------------
# Generales
# -----------------------------------------------------------------------------

variable "project" {
  description = "Nombre del proyecto. Se usa como prefijo de todos los recursos."
  type        = string
  default     = "circleguard"
}

variable "environment" {
  description = "Ambiente que despliega esta raíz: dev, stage o prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment debe ser dev, stage o prod."
  }
}

variable "aws_region" {
  description = "Región de AWS del ambiente."
  type        = string
  default     = "us-east-2"
}

variable "aws_profile" {
  description = "Perfil local de AWS CLI. Con null se usa la cadena de credenciales estándar (variables de entorno, rol de instancia)."
  type        = string
  default     = null
}

variable "services" {
  description = "Imágenes y servicios de CircleGuard: los 8 microservicios y el cliente web."
  type        = list(string)
  default = [
    "auth-service",
    "dashboard-service",
    "file-service",
    "form-service",
    "gateway-service",
    "identity-service",
    "notification-service",
    "promotion-service",
    "web-client",
  ]
}

# -----------------------------------------------------------------------------
# Red (VPC) — US-20
# -----------------------------------------------------------------------------

variable "network_vpc_cidr" {
  description = "Rango de la VPC del ambiente. Debe ser distinto en cada ambiente."
  type        = string
}

variable "network_az_count" {
  description = "Zonas de disponibilidad de la red."
  type        = number
  default     = 2
}

variable "network_enable_nat_gateway" {
  description = "Crea NAT Gateway para las subredes privadas (≈ 32 USD/mes)."
  type        = bool
  default     = false
}

variable "network_enable_flow_logs" {
  description = "Registra el tráfico de la VPC en CloudWatch Logs."
  type        = bool
}

variable "network_flow_logs_retention_days" {
  description = "Días de retención de los Flow Logs."
  type        = number
  default     = 30
}

# -----------------------------------------------------------------------------
# Cómputo (clúster k3s) — US-20
# -----------------------------------------------------------------------------

variable "compute_server_instance_type" {
  description = "Tipo de instancia del nodo server."
  type        = string
}

variable "compute_agent_count" {
  description = "Cantidad de nodos agent adicionales."
  type        = number
}

variable "compute_root_volume_size_gb" {
  description = "Tamaño del disco raíz de cada nodo, en GB."
  type        = number
}

variable "compute_k3s_version" {
  description = "Versión fija de k3s."
  type        = string
  default     = "v1.37.2+k3s1"
}

variable "compute_api_allowed_cidrs" {
  description = "Rangos externos con acceso a la API de Kubernetes. Conviene pasarlos con TF_VAR_compute_api_allowed_cidrs en vez de versionarlos."
  type        = list(string)
  default     = []
}

variable "compute_ingress_allowed_cidrs" {
  description = "Rangos con acceso al Ingress (80/443)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "compute_enable_detailed_monitoring" {
  description = "Métricas de EC2 cada minuto."
  type        = bool
}

variable "compute_enable_termination_protection" {
  description = "Protección contra terminación del nodo server."
  type        = bool
}

# -----------------------------------------------------------------------------
# Registro (ECR)
# -----------------------------------------------------------------------------

variable "registry_image_tag_mutability" {
  description = "Mutabilidad de los tags: MUTABLE o IMMUTABLE."
  type        = string
}

variable "registry_max_image_count" {
  description = "Imágenes que se conservan por repositorio."
  type        = number
}

variable "registry_untagged_image_expiration_days" {
  description = "Días tras los cuales se eliminan las imágenes sin tag."
  type        = number
}

variable "registry_force_delete" {
  description = "Permite borrar repositorios con imágenes."
  type        = bool
}

variable "registry_pull_principal_arns" {
  description = "ARNs IAM autorizados a descargar imágenes (por ejemplo, el rol de los nodos del clúster)."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Almacenamiento (S3)
# -----------------------------------------------------------------------------

variable "storage_buckets" {
  description = "Buckets por propósito y su ciclo de vida (ver modules/storage)."
  type = map(object({
    versioning                         = optional(bool, true)
    noncurrent_version_expiration_days = optional(number, 30)
    transition_to_ia_days              = optional(number)
    expiration_days                    = optional(number)
  }))
}

variable "storage_force_destroy" {
  description = "Permite borrar buckets con objetos."
  type        = bool
}

variable "storage_enable_access_logging" {
  description = "Registra los accesos a los buckets en un bucket de logs."
  type        = bool
}

# -----------------------------------------------------------------------------
# Observabilidad (CloudWatch + SNS)
# -----------------------------------------------------------------------------

variable "observability_log_retention_days" {
  description = "Días de retención de los logs."
  type        = number
}

variable "observability_error_alarm_threshold" {
  description = "Errores por periodo que disparan la alarma de un servicio."
  type        = number
}

variable "observability_kms_key_deletion_window_days" {
  description = "Días de espera antes de borrar la clave KMS."
  type        = number
}

variable "observability_alarm_email_endpoints" {
  description = "Correos de alertas. Conviene pasarlos con la variable de entorno TF_VAR_observability_alarm_email_endpoints en vez de versionarlos."
  type        = list(string)
  default     = []
}
