output "vpc_id" {
  description = "ID de la VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Rango IPv4 de la VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "Zonas de disponibilidad que usa la red, en orden."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "IDs de las subredes públicas, en el mismo orden que availability_zones."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas, en el mismo orden que availability_zones."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "public_subnet_cidrs" {
  description = "Rangos de las subredes públicas, en el mismo orden que availability_zones."
  value       = [for az in local.azs : local.public_subnets[az]]
}

output "private_subnet_cidrs" {
  description = "Rangos de las subredes privadas, en el mismo orden que availability_zones."
  value       = [for az in local.azs : local.private_subnets[az]]
}

output "public_route_table_id" {
  description = "ID de la tabla de rutas pública."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs de las tablas de rutas privadas, en el mismo orden que availability_zones."
  value       = [for az in local.azs : aws_route_table.private[az].id]
}

output "nat_gateway_count" {
  description = "Cantidad de NAT Gateways creados (0 si enable_nat_gateway es false)."
  value       = local.nat_count
}

output "s3_endpoint_id" {
  description = "ID del endpoint gateway de S3, o null si está desactivado."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "flow_logs_log_group_name" {
  description = "Log group de los VPC Flow Logs, o null si están desactivados."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}
