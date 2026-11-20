# Módulo de almacenamiento de objetos (Amazon S3) — US-35
# Buckets privados para documentos y certificados de file-service y para backups.
# Bloquean todo acceso público, cifran con SSE-KMS, solo aceptan TLS 1.2+,
# versionan los objetos y aplican reglas de ciclo de vida.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  suffix = coalesce(var.bucket_name_suffix, "${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}")

  bucket_names = {
    for purpose, _ in var.buckets : purpose => "${var.name_prefix}-${var.environment}-${purpose}-${local.suffix}"
  }

  log_bucket_name = "${var.name_prefix}-${var.environment}-access-logs-${local.suffix}"

  tags = merge(var.tags, {
    Component = "storage"
  })
}

# -----------------------------------------------------------------------------
# Buckets de datos
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  for_each = local.bucket_names

  bucket        = each.value
  force_destroy = var.force_destroy

  tags = merge(local.tags, {
    Purpose = each.key
  })

  lifecycle {
    precondition {
      condition     = length(each.value) <= 63
      error_message = "El nombre del bucket ${each.value} supera los 63 caracteres. Usa un bucket_name_suffix más corto."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = var.buckets[each.key].versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = var.buckets[each.key].versioning ? "Enabled" : "Disabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.buckets[each.key].noncurrent_version_expiration_days
    }
  }

  dynamic "rule" {
    for_each = var.buckets[each.key].transition_to_ia_days == null ? [] : [var.buckets[each.key].transition_to_ia_days]

    content {
      id     = "transition-to-standard-ia"
      status = "Enabled"

      filter {}

      transition {
        days          = rule.value
        storage_class = "STANDARD_IA"
      }
    }
  }

  dynamic "rule" {
    for_each = var.buckets[each.key].expiration_days == null ? [] : [var.buckets[each.key].expiration_days]

    content {
      id     = "expire-current-objects"
      status = "Enabled"

      filter {}

      expiration {
        days = rule.value
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [each.value.arn, "${each.value.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOutdatedTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [each.value.arn, "${each.value.arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
    ]
  })

  # La política solo se aplica una vez bloqueado el acceso público.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_logging" "this" {
  for_each = var.enable_access_logging ? aws_s3_bucket.this : {}

  bucket        = each.value.id
  target_bucket = aws_s3_bucket.access_logs[0].id
  target_prefix = "${each.key}/"
}

# -----------------------------------------------------------------------------
# Bucket de logs de acceso (opcional)
# La entrega de logs de S3 exige cifrado SSE-S3 (AES256) en el bucket destino.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket        = local.log_bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.tags, {
    Purpose = "access-logs"
  })

  lifecycle {
    precondition {
      condition     = length(local.log_bucket_name) <= 63
      error_message = "El nombre del bucket ${local.log_bucket_name} supera los 63 caracteres. Usa un bucket_name_suffix más corto."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket                  = aws_s3_bucket.access_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.access_logs]
}

resource "aws_s3_bucket_policy" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ServerAccessLogs"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs[0].arn}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike = {
            "aws:SourceArn" = [for b in aws_s3_bucket.this : b.arn]
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs[0].arn, "${aws_s3_bucket.access_logs[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}

# -----------------------------------------------------------------------------
# Política IAM de acceso a los datos (para el rol de file-service u otros)
# -----------------------------------------------------------------------------

locals {
  kms_statement = var.kms_key_arn == null ? [] : [
    {
      Sid      = "UseBucketKmsKey"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = var.kms_key_arn
    },
  ]

  read_write_policy = {
    for purpose, bucket in aws_s3_bucket.this : purpose => jsonencode({
      Version = "2012-10-17"
      Statement = concat([
        {
          Sid      = "ListBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = bucket.arn
        },
        {
          Sid      = "ReadWriteObjects"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = "${bucket.arn}/*"
        },
      ], local.kms_statement)
    })
  }
}
