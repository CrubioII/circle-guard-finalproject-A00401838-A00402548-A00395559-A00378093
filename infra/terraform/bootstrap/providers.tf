# Sin credenciales en el código: el proveedor usa la cadena estándar de AWS
# (aws_profile o AWS_PROFILE, variables de entorno o rol).
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      Component   = "terraform-state"
      ManagedBy   = "terraform"
      Repository  = "circle-guard"
    }
  }
}
