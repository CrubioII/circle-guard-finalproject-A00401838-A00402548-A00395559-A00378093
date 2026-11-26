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
  description = "Ambiente al que pertenece el clúster: dev, stage o prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment debe ser dev, stage o prod."
  }
}

# -----------------------------------------------------------------------------
# Red (salidas del módulo network)
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC donde se crean los nodos."
  type        = string
}

variable "vpc_cidr" {
  description = "Rango de la VPC. Desde él se permite el acceso a la API de Kubernetes."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr debe ser un CIDR IPv4 válido."
  }
}

variable "subnet_ids" {
  description = "Subredes de los nodos. El server usa la primera y los agents se reparten en todas."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids debe tener al menos una subred."
  }
}

variable "assign_public_ip" {
  description = "Asigna IP pública a los agents para salir a internet sin NAT. El server siempre usa una IP elástica."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Nodos
# -----------------------------------------------------------------------------

variable "server_instance_type" {
  description = "Tipo de instancia del nodo server (plano de control y cargas)."
  type        = string
  default     = "m7i-flex.large"
}

variable "agent_count" {
  description = "Cantidad de nodos agent (solo cargas). 0 deja un clúster de un nodo."
  type        = number
  default     = 0

  validation {
    condition     = var.agent_count >= 0 && var.agent_count <= 10 && floor(var.agent_count) == var.agent_count
    error_message = "agent_count debe ser un entero entre 0 y 10."
  }
}

variable "agent_instance_type" {
  description = "Tipo de instancia de los agents. Con null se usa server_instance_type."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Tamaño en GB del disco raíz gp3 de cada nodo (imágenes y volúmenes locales)."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size_gb >= 20 && var.root_volume_size_gb <= 500
    error_message = "root_volume_size_gb debe estar entre 20 y 500."
  }
}

variable "ebs_kms_key_arn" {
  description = "Clave KMS para cifrar los discos. Con null se usa la clave administrada por AWS (aws/ebs)."
  type        = string
  default     = null
}

variable "ami_ssm_parameter" {
  description = "Parámetro SSM público con el ID de la AMI. Por defecto, la última Amazon Linux 2023 x86_64."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "enable_detailed_monitoring" {
  description = "Activa las métricas de EC2 cada minuto (tiene costo)."
  type        = bool
  default     = false
}

variable "enable_termination_protection" {
  description = "Impide terminar el nodo server desde la API o la consola sin desactivar antes la protección."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Kubernetes (k3s)
# -----------------------------------------------------------------------------

variable "k3s_version" {
  description = "Versión fija de k3s (canal stable). Fijarla hace que cada ambiente sea reproducible."
  type        = string
  default     = "v1.37.2+k3s1"

  validation {
    condition     = can(regex("^v1\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version debe tener el formato v1.X.Y+k3sN, por ejemplo v1.37.2+k3s1."
  }
}

variable "api_allowed_cidrs" {
  description = "Rangos externos que pueden llegar a la API de Kubernetes (6443), además de la VPC. Vacío: solo desde la VPC o por túnel de SSM."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "api_allowed_cidrs debe contener CIDR válidos y no puede abrir la API a 0.0.0.0/0."
  }
}

variable "ingress_allowed_cidrs" {
  description = "Rangos que pueden llegar al Ingress de Kubernetes (80 y 443). Para un servicio público es 0.0.0.0/0."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.ingress_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "ingress_allowed_cidrs debe contener CIDR válidos."
  }
}

variable "insecure_registries" {
  description = "Registros host:puerto que sirven por HTTP (Nexus). Se escriben en /etc/rancher/k3s/registries.yaml de cada nodo nuevo (P2). El server existente ignora cambios del launch template, así que no se reinicia."
  type        = list(string)
  default     = []
}

variable "node_labels" {
  description = "Etiquetas adicionales de Kubernetes para todos los nodos (clave = valor)."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# IAM
# -----------------------------------------------------------------------------

variable "enable_ecr_pull" {
  description = "Permite a los nodos descargar imágenes de ECR (US-35)."
  type        = bool
  default     = true
}

variable "enable_cloudwatch_agent" {
  description = "Permite a los nodos enviar logs y métricas a CloudWatch."
  type        = bool
  default     = true
}

variable "additional_iam_policy_arns" {
  description = "Políticas IAM administradas adicionales para el rol de los nodos."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags adicionales para todos los recursos del módulo."
  type        = map(string)
  default     = {}
}
