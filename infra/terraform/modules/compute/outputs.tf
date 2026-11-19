output "cluster_name" {
  description = "Nombre del clúster k3s."
  value       = "${local.base_name}-k3s"
}

output "k3s_version" {
  description = "Versión de k3s instalada."
  value       = var.k3s_version
}

output "server_instance_id" {
  description = "ID de la instancia del nodo server (para SSM Session Manager)."
  value       = aws_instance.server.id
}

output "server_private_ip" {
  description = "IP privada del nodo server."
  value       = aws_instance.server.private_ip
}

output "server_public_ip" {
  description = "IP elástica del nodo server. No cambia al reiniciar la instancia."
  value       = aws_eip.server.public_ip
}

output "api_endpoint" {
  description = "Endpoint de la API de Kubernetes."
  value       = "https://${aws_eip.server.public_ip}:6443"
}

output "agent_instance_ids" {
  description = "IDs de las instancias agent."
  value       = aws_instance.agent[*].id
}

output "node_count" {
  description = "Cantidad total de nodos (server + agents)."
  value       = 1 + var.agent_count
}

output "node_security_group_id" {
  description = "Security group de los nodos."
  value       = aws_security_group.node.id
}

output "node_role_arn" {
  description = "ARN del rol IAM de los nodos (para políticas de ECR, S3 u otras)."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Nombre del rol IAM de los nodos, para adjuntarle políticas adicionales."
  value       = aws_iam_role.node.name
}

output "kube_api_allowed_cidrs" {
  description = "Rangos con acceso a la API de Kubernetes."
  value       = local.api_cidrs
}

output "node_token_parameter_name" {
  description = "Parámetro SSM (SecureString) con el token de unión del clúster."
  value       = aws_ssm_parameter.node_token.name
}

output "kubeconfig_parameter_name" {
  description = "Parámetro SSM (SecureString) con el kubeconfig de administración."
  value       = aws_ssm_parameter.kubeconfig.name
}
