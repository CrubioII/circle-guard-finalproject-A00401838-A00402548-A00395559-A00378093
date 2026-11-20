# Módulo de registro de imágenes (Amazon ECR) — US-35
# Un repositorio privado por servicio, con escaneo al subir, cifrado KMS y
# política de ciclo de vida para controlar el costo de almacenamiento.

locals {
  repository_names = {
    for repo in var.repositories : repo => "${var.name_prefix}/${var.environment}/${repo}"
  }

  # Las reglas con tagStatus = "any" deben tener la prioridad más baja (número mayor).
  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Elimina imagenes sin tag despues de ${var.untagged_image_expiration_days} dias"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiration_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Conserva solo las ultimas ${var.max_image_count} imagenes"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = { type = "expire" }
      },
    ]
  })

  tags = merge(var.tags, {
    Component = "registry"
  })
}

resource "aws_ecr_repository" "this" {
  for_each = local.repository_names

  name                 = each.value
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(local.tags, {
    Service = each.key
  })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy     = local.lifecycle_policy
}

resource "aws_ecr_repository_policy" "pull" {
  for_each = length(var.pull_principal_arns) > 0 ? aws_ecr_repository.this : {}

  repository = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPullFromPlatform"
        Effect    = "Allow"
        Principal = { AWS = var.pull_principal_arns }
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
      },
    ]
  })
}
