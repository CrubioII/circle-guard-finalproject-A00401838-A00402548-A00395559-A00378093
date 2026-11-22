terraform {
  # use_lockfile (bloqueo nativo en S3) requiere Terraform 1.10 o superior y
  # terraform test con override_during = plan requiere 1.11.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
