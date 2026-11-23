# Plan del backend remoto con proveedor simulado. No necesita credenciales AWS:
#   cd infra/terraform/bootstrap && terraform init -backend=false && terraform test

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::circleguard-terraform-state-123456789012"
    }
  }
}

run "plan_backend" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "circleguard-terraform-state-123456789012"
    error_message = "El bucket de estado debe llevar el ID de la cuenta."
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false
    error_message = "El bucket de estado no debe poder borrarse con objetos."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "El bucket de estado debe tener versionado."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "El bucket de estado debe bloquear todo acceso público."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "El estado debe cifrarse con SSE-S3."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "El bucket de estado no debe usar ACL."
  }

  assert {
    condition = contains(
      [for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Sid],
      "DenyInsecureTransport",
    )
    error_message = "La política del bucket debe rechazar conexiones sin TLS."
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_lifecycle_configuration.state.rule :
      r.id == "expire-noncurrent-state-versions" && one(r.noncurrent_version_expiration).noncurrent_days == 90
    ])
    error_message = "Las versiones anteriores del estado deben conservarse 90 días."
  }

  assert {
    condition     = output.state_keys.dev == "envs/dev/platform.tfstate" && output.state_keys.prod == "envs/prod/platform.tfstate"
    error_message = "Cada ambiente debe tener su propia clave de estado."
  }
}

run "rechaza_retencion_corta" {
  command = plan

  variables {
    noncurrent_version_expiration_days = 7
  }

  expect_failures = [var.noncurrent_version_expiration_days]
}
