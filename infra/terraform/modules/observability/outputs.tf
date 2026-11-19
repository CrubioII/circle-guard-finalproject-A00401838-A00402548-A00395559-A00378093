output "log_group_names" {
  description = "Nombre del log group de cada servicio."
  value       = { for k, lg in aws_cloudwatch_log_group.service : k => lg.name }
}

output "log_group_arns" {
  description = "ARN del log group de cada servicio. Sirve para políticas IAM del agente de logs."
  value       = { for k, lg in aws_cloudwatch_log_group.service : k => lg.arn }
}

output "log_retention_days" {
  description = "Retención aplicada a los log groups."
  value       = var.log_retention_days
}

output "metric_namespace" {
  description = "Namespace de CloudWatch donde se publican las métricas de errores."
  value       = local.metric_namespace
}

output "alarm_names" {
  description = "Nombre de la alarma de errores de cada servicio."
  value       = { for k, a in aws_cloudwatch_metric_alarm.service_errors : k => a.alarm_name }
}

output "alerts_topic_arn" {
  description = "ARN del topic SNS de alertas (también lo puede usar Alertmanager)."
  value       = aws_sns_topic.alerts.arn
}

output "kms_key_arn" {
  description = "ARN de la clave KMS que cifra los logs y el topic de alertas."
  value       = aws_kms_key.this.arn
}

output "dashboard_name" {
  description = "Nombre del dashboard de CloudWatch, o null si enable_dashboard es false."
  value       = try(aws_cloudwatch_dashboard.this[0].dashboard_name, null)
}
