# Pruebas del módulo registry con proveedor simulado: no necesitan credenciales AWS.
#   cd infra/terraform/modules/registry && terraform init -backend=false && terraform test

mock_provider "aws" {}

variables {
  environment  = "dev"
  repositories = ["auth-service", "gateway-service", "web-client"]
}

run "crea_un_repositorio_por_servicio_con_prefijo_de_ambiente" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository.this) == 3
    error_message = "Debe existir un repositorio por cada servicio."
  }

  assert {
    condition     = aws_ecr_repository.this["auth-service"].name == "circleguard/dev/auth-service"
    error_message = "El repositorio debe llamarse <prefijo>/<ambiente>/<servicio>."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_scanning_configuration[0].scan_on_push])
    error_message = "Todos los repositorios deben escanear las imágenes al subirlas."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.encryption_configuration[0].encryption_type == "KMS"])
    error_message = "Todos los repositorios deben cifrar con KMS."
  }

  assert {
    condition     = length(aws_ecr_lifecycle_policy.this) == 3
    error_message = "Cada repositorio debe tener política de ciclo de vida."
  }

  assert {
    condition     = length(aws_ecr_repository_policy.pull) == 0
    error_message = "Sin pull_principal_arns no debe crearse política de repositorio."
  }
}

run "prod_usa_tags_inmutables_y_no_permite_borrado_forzado" {
  command = plan

  variables {
    environment          = "prod"
    image_tag_mutability = "IMMUTABLE"
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE" && !r.force_delete])
    error_message = "En prod los tags deben ser inmutables y el borrado forzado debe estar apagado."
  }

  assert {
    condition     = aws_ecr_repository.this["web-client"].name == "circleguard/prod/web-client"
    error_message = "El prefijo de ambiente debe ser prod."
  }
}

run "politica_de_pull_para_el_rol_de_los_nodos" {
  command = plan

  variables {
    pull_principal_arns = ["arn:aws:iam::123456789012:role/circleguard-dev-nodes"]
  }

  assert {
    condition     = length(aws_ecr_repository_policy.pull) == 3
    error_message = "Con pull_principal_arns debe existir una política de pull por repositorio."
  }
}

run "rechaza_ambientes_desconocidos" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}

run "rechaza_repositorios_repetidos" {
  command = plan

  variables {
    repositories = ["auth-service", "auth-service"]
  }

  expect_failures = [var.repositories]
}
