# Sin credenciales en el código: el proveedor usa la cadena estándar de AWS
# (aws_profile o AWS_PROFILE, variables de entorno de la sesión, rol de instancia
# o rol asumido por Jenkins).
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Story       = "US-35"
    }
  }
}
