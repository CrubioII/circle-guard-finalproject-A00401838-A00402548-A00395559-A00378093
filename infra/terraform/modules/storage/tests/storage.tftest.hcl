# Pruebas del módulo storage con proveedor simulado: no necesitan credenciales AWS.
#   cd infra/terraform/modules/storage && terraform init -backend=false && terraform test

mock_provider "aws" {
  # Los valores simulados se usan ya en el plan (Terraform >= 1.11).
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::circleguard-mock-bucket"
    }
  }
}

variables {
  environment = "dev"
}

run "crea_buckets_privados_cifrados_y_con_tls" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this["documents"].bucket == "circleguard-dev-documents-123456789012-us-east-2"
    error_message = "El bucket debe llamarse <prefijo>-<ambiente>-<propósito>-<cuenta>-<región>."
  }

  assert {
    condition = alltrue([
      for b in aws_s3_bucket_public_access_block.this :
      b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets
    ])
    error_message = "Todos los buckets deben bloquear el acceso público."
  }

  assert {
    condition = alltrue([
      for c in aws_s3_bucket_server_side_encryption_configuration.this :
      one(c.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    ])
    error_message = "Todos los buckets deben cifrar con SSE-KMS."
  }

  assert {
    condition     = alltrue([for p in aws_s3_bucket_policy.this : strcontains(p.policy, "aws:SecureTransport")])
    error_message = "La política de cada bucket debe rechazar conexiones sin TLS."
  }

  assert {
    condition     = alltrue([for o in aws_s3_bucket_ownership_controls.this : o.rule[0].object_ownership == "BucketOwnerEnforced"])
    error_message = "Las ACL deben estar deshabilitadas (BucketOwnerEnforced)."
  }

  assert {
    condition     = aws_s3_bucket_versioning.this["documents"].versioning_configuration[0].status == "Enabled"
    error_message = "El versionado debe estar activo por defecto."
  }

  assert {
    condition     = length(aws_s3_bucket.access_logs) == 0 && length(aws_s3_bucket_logging.this) == 0
    error_message = "Sin enable_access_logging no debe existir bucket de logs."
  }
}

run "prod_activa_logs_de_acceso_y_ciclo_de_vida" {
  command = plan

  variables {
    environment           = "prod"
    enable_access_logging = true
    buckets = {
      documents = { transition_to_ia_days = 90 }
      backups   = { transition_to_ia_days = 30, expiration_days = 365 }
    }
  }

  assert {
    condition     = aws_s3_bucket.access_logs[0].bucket == "circleguard-prod-access-logs-123456789012-us-east-2"
    error_message = "Debe existir el bucket de logs de acceso de prod."
  }

  assert {
    condition     = length(aws_s3_bucket_logging.this) == 2
    error_message = "Cada bucket de datos debe enviar sus logs de acceso."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.access_logs[0].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "El bucket de logs debe usar SSE-S3, el único cifrado que admite la entrega de logs."
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this["backups"].rule) == 4
    error_message = "backups debe tener las reglas de multipart, versiones, transición y expiración."
  }

  assert {
    condition     = alltrue([for b in aws_s3_bucket.this : !b.force_destroy])
    error_message = "En prod no se deben poder borrar buckets con datos."
  }
}

run "rechaza_transicion_menor_a_30_dias" {
  command = plan

  variables {
    buckets = {
      documents = { transition_to_ia_days = 10 }
    }
  }

  expect_failures = [var.buckets]
}

run "rechaza_nombres_de_bucket_demasiado_largos" {
  command = plan

  variables {
    bucket_name_suffix = "un-sufijo-demasiado-largo-para-s3-000000000000"
  }

  expect_failures = [aws_s3_bucket.this]
}
