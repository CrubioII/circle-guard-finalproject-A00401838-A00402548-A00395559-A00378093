# Costos de infraestructura (Parte 2, entregable E2.9)

Este documento compara lo que costaría la infraestructura de CircleGuard a precio de lista con lo que AWS cobró de verdad en noviembre de 2026.

## 1. Qué se paga

Todo está en `us-east-2`. Los tamaños salen de `infra/terraform/envs/<env>/terraform.tfvars` y de `infra/bootstrap/bootstrap-ci.sh`.

| Recurso | Cantidad | Detalle |
| :--- | :--- | :--- |
| EC2 `m7i-flex.large` (2 vCPU, 8 GiB) | 4 | Un server k3s por ambiente (dev, stage, prod) y el servidor de CI (Jenkins, SonarQube, Nexus) |
| EBS gp3 | 150 GB | 30 (dev) + 40 (stage) + 50 (prod) + 30 (CI) |
| IPv4 pública | 4 | Una IP elástica por server k3s y la del servidor de CI |
| S3, ECR, CloudWatch, KMS, SNS | poco uso | Estado de Terraform, buckets de `storage`, repositorio de `registry`, dashboard y alarma de `observability` |

Los ambientes no usan NAT Gateway: los nodos están en subredes públicas y salen por su IP. Eso evita unos 32 USD al mes por ambiente.

## 2. Estimación a precio de lista

Precios on-demand de lista de `us-east-2` (página de precios de AWS, noviembre de 2026). Son aproximados: antes de presentarlos conviene confirmarlos en la [AWS Pricing Calculator](https://calculator.aws/).

| Concepto | Precio unitario | Cálculo | USD/mes |
| :--- | :--- | :--- | ---: |
| EC2 `m7i-flex.large` | ~0,096 USD/h | 4 × 730 h | ~280 |
| EBS gp3 | 0,08 USD/GB-mes | 150 GB | 12 |
| IPv4 pública | 0,005 USD/h | 4 × 730 h | ~15 |
| S3, ECR, CloudWatch, KMS, SNS | | uso bajo | ~3 |
| **Total con todo encendido 24/7** | | | **~310** |

Por ambiente, un server k3s cuesta unos 80 USD/mes encendido todo el tiempo (instancia, disco e IP).

## 3. Costo real

Datos de AWS Cost Explorer para la cuenta del proyecto, del 1 al 25 de noviembre de 2026, filtrando solo el uso (sin créditos):

| Servicio | USD |
| :--- | ---: |
| Amazon Lightsail | 13,80 |
| EC2 (cómputo) | 3,63 |
| Amazon VPC (IPv4 públicas) | 3,01 |
| EC2 - Other (EBS, IP elásticas) | 1,33 |
| ECR | 0,05 |
| S3, KMS, CloudWatch | 0,00 |
| **Uso total** | **21,82** |
| Créditos aplicados | −21,82 |
| **Cobrado** | **0,00** |

La cuenta está en el plan pagado con créditos y le quedan unos 148 USD.

Para repetir la consulta:

```bash
aws ce get-cost-and-usage --time-period Start=2026-11-01,End=2026-11-26 \
  --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE \
  --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'
```

## 4. Por qué el real es mucho menor que la estimación

- La cuenta se migró a mitad del proyecto (`chore/aws-account-migration`, PR #31), así que estos datos no incluyen lo que se gastó en la cuenta anterior.
- Las instancias no estuvieron encendidas todo el mes. Los servers de Terraform se crearon en la segunda mitad de noviembre y las tres instancias de US-05 quedaron detenidas (ver `docs/arquitectura/PENDIENTES_PIPELINE_PLATAFORMA.md`, P9).
- Lightsail no lo crea Terraform ni los scripts del repositorio. Hay que revisar en la consola qué recurso es y apagarlo si no se usa.

## 5. Cómo se controla el gasto

- Al terminar la evaluación se destruye todo con `terraform destroy` en `envs/prod`, `envs/stage` y `envs/dev`, y después el bootstrap del estado. El servidor de CI se detiene o se termina aparte.
- Los ambientes tienen un solo nodo (`compute_agent_count = 0`). Subir ese valor agrega capacidad pero suma unos 70 USD/mes por nodo.
- Detener dev y stage fuera de las horas de trabajo (unas 10 h al día en días hábiles) bajaría la estimación a unos 180 USD/mes.
- Los créditos restantes se revisan en AWS Settings > Billing.
