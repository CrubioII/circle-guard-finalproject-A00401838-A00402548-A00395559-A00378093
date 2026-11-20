# Pruebas del módulo observability con proveedor simulado: no necesitan credenciales AWS.
#   cd infra/terraform/modules/observability && terraform init -backend=false && terraform test

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

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-2:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-2:123456789012:circleguard-dev-alerts"
    }
  }
}

variables {
  environment        = "dev"
  services           = ["auth-service", "form-service"]
  log_retention_days = 7
}

run "crea_logs_cifrados_metricas_y_alarmas_por_servicio" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.service["auth-service"].name == "/circleguard/dev/auth-service"
    error_message = "El log group debe llamarse /<prefijo>/<ambiente>/<servicio>."
  }

  assert {
    condition     = alltrue([for lg in aws_cloudwatch_log_group.service : lg.retention_in_days == 7 && lg.kms_key_id != null])
    error_message = "Los log groups deben tener la retención indicada y cifrado KMS."
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.errors) == 2 && length(aws_cloudwatch_metric_alarm.service_errors) == 2
    error_message = "Cada servicio debe tener filtro de errores y alarma."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.service_errors : contains(a.alarm_actions, aws_sns_topic.alerts.arn)])
    error_message = "Las alarmas deben notificar al topic de alertas."
  }

  assert {
    condition     = aws_sns_topic.alerts.kms_master_key_id == aws_kms_key.this.arn
    error_message = "El topic de alertas debe estar cifrado con la clave propia."
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation
    error_message = "La clave KMS debe rotar automáticamente."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "Sin correos no deben crearse suscripciones."
  }

  assert {
    condition     = output.metric_namespace == "CircleGuard/dev"
    error_message = "Las métricas deben publicarse en CircleGuard/<ambiente>."
  }

  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 1
    error_message = "El dashboard debe crearse por defecto."
  }
}

run "suscribe_correos_y_permite_apagar_el_dashboard" {
  command = plan

  variables {
    environment           = "prod"
    alarm_email_endpoints = ["oncall@example.com"]
    enable_dashboard      = false
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "Debe existir una suscripción por correo."
  }

  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 0 && output.dashboard_name == null
    error_message = "Con enable_dashboard = false no debe crearse dashboard."
  }
}

run "rechaza_retenciones_no_soportadas" {
  command = plan

  variables {
    log_retention_days = 10
  }

  expect_failures = [var.log_retention_days]
}

run "rechaza_correos_invalidos" {
  command = plan

  variables {
    alarm_email_endpoints = ["no-es-un-correo"]
  }

  expect_failures = [var.alarm_email_endpoints]
}
