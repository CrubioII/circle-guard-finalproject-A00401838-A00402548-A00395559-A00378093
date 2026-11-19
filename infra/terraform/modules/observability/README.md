# Módulo `observability` — CloudWatch + SNS

Base de observabilidad en AWS para cada ambiente. Crea:

- un **log group por servicio** (`/<name_prefix>/<environment>/<servicio>`), con retención según el ambiente y cifrado con una clave KMS propia;
- un **filtro de métricas** por servicio que cuenta las líneas de error (`?ERROR ?Exception`) en el namespace `CircleGuard/<environment>`;
- una **alarma por servicio** que avisa cuando los errores superan el umbral, y otra vez cuando se recupera;
- un **topic SNS de alertas** cifrado, con suscripción opcional por correo;
- un **dashboard** de CloudWatch con los errores por servicio y el estado de las alarmas;
- una **clave KMS** con rotación automática.

La clave KMS es propia porque CloudWatch Alarms no puede publicar en un topic SNS cifrado con la clave administrada por AWS (`alias/aws/sns`).

Prometheus, Grafana, Jaeger y Loki (E2.5) corren dentro de Kubernetes. Este módulo entrega la parte administrada por AWS, y Alertmanager puede publicar en el mismo topic (`alerts_topic_arn`).

## Uso

```hcl
module "observability" {
  source = "../../modules/observability"

  environment           = "prod"
  services              = ["auth-service", "form-service"]
  log_retention_days    = 30
  error_alarm_threshold = 5
  alarm_email_endpoints = var.alarm_email_endpoints # desde TF_VAR_, no versionado
}
```

## Entradas

| Nombre | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `environment` | `string` | — (obligatoria) | `dev`, `stage` o `prod`. |
| `services` | `list(string)` | — (obligatoria) | Servicios con log group, métrica y alarma. |
| `name_prefix` | `string` | `"circleguard"` | Prefijo de los recursos. |
| `log_retention_days` | `number` | `30` | Retención. Solo valores que admite CloudWatch (1, 3, 5, 7, 14, 30, 60, 90…). |
| `kms_key_deletion_window_days` | `number` | `30` | Espera antes de borrar la clave (7 a 30). |
| `error_log_pattern` | `string` | `"?ERROR ?Exception"` | Patrón que cuenta una línea como error. |
| `error_alarm_threshold` | `number` | `10` | Errores por periodo que disparan la alarma. |
| `error_alarm_period_seconds` | `number` | `300` | Periodo evaluado: 60, 300, 900 o 3600. |
| `error_alarm_evaluation_periods` | `number` | `1` | Periodos seguidos sobre el umbral. |
| `alarm_email_endpoints` | `list(string)` | `[]` | Correos de alertas. Cada uno debe confirmar su suscripción. |
| `enable_dashboard` | `bool` | `true` | Crea el dashboard. |
| `tags` | `map(string)` | `{}` | Tags adicionales. |

## Salidas

| Nombre | Descripción |
|---|---|
| `log_group_names` | Log group de cada servicio. |
| `log_group_arns` | ARN de cada log group (para el agente de logs). |
| `log_retention_days` | Retención aplicada. |
| `metric_namespace` | Namespace de las métricas de errores. |
| `alarm_names` | Alarma de cada servicio. |
| `alerts_topic_arn` | Topic SNS de alertas. |
| `kms_key_arn` | Clave KMS de logs y alertas. |
| `dashboard_name` | Dashboard, o `null`. |

## Pruebas

```bash
cd infra/terraform/modules/observability
terraform init -backend=false
terraform test   # proveedor simulado, sin credenciales
```
