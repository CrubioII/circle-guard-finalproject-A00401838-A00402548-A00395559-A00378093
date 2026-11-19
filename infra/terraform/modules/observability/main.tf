# Módulo de observabilidad base (CloudWatch + SNS) — US-35
# Log groups cifrados por servicio, métrica y alarma de errores por servicio,
# topic SNS de alertas y dashboard. Prometheus, Grafana, Jaeger y Loki corren
# en Kubernetes (E2.5) y pueden publicar en el mismo topic de alertas.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  base_name         = "${var.name_prefix}-${var.environment}"
  log_group_prefix  = "/${var.name_prefix}/${var.environment}"
  metric_namespace  = "CircleGuard/${var.environment}"
  log_group_names   = { for s in var.services : s => "${local.log_group_prefix}/${s}" }
  error_metric_name = { for s in var.services : s => "${s}-error-count" }

  tags = merge(var.tags, {
    Component = "observability"
  })
}

# -----------------------------------------------------------------------------
# Clave KMS propia: CloudWatch Alarms no puede publicar en un topic SNS cifrado
# con la clave administrada por AWS (alias/aws/sns), por eso se crea una clave
# con permisos explícitos para Logs, CloudWatch y SNS.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "this" {
  description             = "Cifrado de logs y alertas de ${local.base_name}"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_prefix}/*"
          }
        }
      },
      {
        Sid       = "AllowAlarmsToPublishEncrypted"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "sns.amazonaws.com"] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.base_name}-observability"
  target_key_id = aws_kms_key.this.key_id
}

# -----------------------------------------------------------------------------
# Logs por servicio
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "service" {
  for_each = local.log_group_names

  name              = each.value
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn

  tags = merge(local.tags, {
    Service = each.key
  })
}

resource "aws_cloudwatch_log_metric_filter" "errors" {
  for_each = aws_cloudwatch_log_group.service

  name           = "${local.base_name}-${each.key}-errors"
  log_group_name = each.value.name
  pattern        = var.error_log_pattern

  metric_transformation {
    name          = local.error_metric_name[each.key]
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# -----------------------------------------------------------------------------
# Alertas
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name              = "${local.base_name}-alerts"
  kms_master_key_id = aws_kms_key.this.arn

  tags = local.tags
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_email_endpoints)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "service_errors" {
  for_each = aws_cloudwatch_log_metric_filter.errors

  alarm_name          = "${local.base_name}-${each.key}-errors"
  alarm_description   = "Errores de ${each.key} en ${var.environment}: ${var.error_alarm_threshold} o más en ${var.error_alarm_period_seconds} s."
  namespace           = local.metric_namespace
  metric_name         = local.error_metric_name[each.key]
  statistic           = "Sum"
  period              = var.error_alarm_period_seconds
  evaluation_periods  = var.error_alarm_evaluation_periods
  threshold           = var.error_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = merge(local.tags, {
    Service = each.key
  })
}

resource "aws_cloudwatch_dashboard" "this" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${local.base_name}-platform"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 8
        properties = {
          title   = "Errores por servicio (${var.environment})"
          region  = local.region
          view    = "timeSeries"
          stacked = false
          stat    = "Sum"
          period  = var.error_alarm_period_seconds
          metrics = [for s in var.services : [local.metric_namespace, local.error_metric_name[s], { label = s }]]
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 8
        width  = 24
        height = 6
        properties = {
          title  = "Estado de las alarmas (${var.environment})"
          alarms = [for a in aws_cloudwatch_metric_alarm.service_errors : a.arn]
        }
      },
    ]
  })
}
