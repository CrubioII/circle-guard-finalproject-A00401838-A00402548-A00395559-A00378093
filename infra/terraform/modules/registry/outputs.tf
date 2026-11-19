output "repository_names" {
  description = "Nombre completo de cada repositorio, por servicio."
  value       = { for k, repo in aws_ecr_repository.this : k => repo.name }
}

output "repository_urls" {
  description = "URL de cada repositorio (<cuenta>.dkr.ecr.<región>.amazonaws.com/<nombre>), por servicio."
  value       = { for k, repo in aws_ecr_repository.this : k => repo.repository_url }
}

output "repository_arns" {
  description = "ARN de cada repositorio, por servicio. Sirve para políticas IAM de push y pull."
  value       = { for k, repo in aws_ecr_repository.this : k => repo.arn }
}

output "registry_id" {
  description = "ID de la cuenta dueña del registro."
  value       = one(distinct([for repo in aws_ecr_repository.this : repo.registry_id]))
}

output "registry_url" {
  description = "Host del registro para docker login (<cuenta>.dkr.ecr.<región>.amazonaws.com)."
  value       = one(distinct([for repo in aws_ecr_repository.this : split("/", repo.repository_url)[0]]))
}

output "image_tag_mutability" {
  description = "Mutabilidad de tags aplicada a los repositorios."
  value       = var.image_tag_mutability
}
