# Módulo `network` — Amazon VPC

Crea la red propia de un ambiente:

- una **VPC** con DNS habilitado;
- una **subred pública y una privada por zona de disponibilidad** (2 por defecto). Las públicas usan los índices `0..n-1` del CIDR y las privadas `10..10+n-1`. Con `10.10.0.0/16` quedan las públicas `10.10.0.0/24`, `10.10.1.0/24` y las privadas `10.10.10.0/24`, `10.10.11.0/24`;
- un **Internet Gateway** y la tabla de rutas pública con salida a internet;
- una tabla de rutas privada por zona, para usar el NAT de la misma zona;
- un **NAT Gateway opcional**, uno solo o uno por zona;
- un **endpoint gateway de S3** gratuito, para que el tráfico a S3 y a las capas de ECR no salga a internet;
- **VPC Flow Logs opcionales** en CloudWatch Logs;
- el **security group por defecto sin reglas**, para que ningún recurso lo use por accidente.

Las subredes públicas no asignan IP pública automáticamente. Cada instancia decide si la necesita (en su launch template) o usa una IP elástica. Las subredes llevan las etiquetas `kubernetes.io/role/elb` e `internal-elb` que usan los balanceadores de Kubernetes.

## Uso

```hcl
module "network" {
  source = "../../modules/network"

  environment      = "prod"
  vpc_cidr         = "10.30.0.0/16"
  az_count         = 2
  enable_flow_logs = true
}
```

## Entradas

| Nombre | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `environment` | `string` | — (obligatoria) | `dev`, `stage` o `prod`. |
| `vpc_cidr` | `string` | — (obligatoria) | CIDR IPv4 de la VPC, entre `/16` y `/20`. Debe ser distinto por ambiente. |
| `name_prefix` | `string` | `"circleguard"` | Prefijo de los recursos. |
| `az_count` | `number` | `2` | Zonas de disponibilidad (1 a 3). |
| `subnet_newbits` | `number` | `8` | Bits agregados a la máscara para cada subred (4 a 12). Con `/16` y 8 bits, cada subred es `/24`. |
| `enable_nat_gateway` | `bool` | `false` | Crea NAT Gateway para las subredes privadas (≈ 32 USD/mes cada uno). |
| `single_nat_gateway` | `bool` | `true` | Un NAT para todas las zonas, o uno por zona si es `false`. |
| `enable_s3_endpoint` | `bool` | `true` | Endpoint gateway de S3. |
| `enable_flow_logs` | `bool` | `false` | VPC Flow Logs en CloudWatch Logs. |
| `flow_logs_retention_days` | `number` | `30` | Retención de los Flow Logs (valores que admite CloudWatch). |
| `flow_logs_kms_key_arn` | `string` | `null` | Clave KMS del log group de Flow Logs. |
| `tags` | `map(string)` | `{}` | Tags adicionales. |

## Salidas

| Nombre | Descripción |
|---|---|
| `vpc_id` | ID de la VPC. |
| `vpc_cidr` | CIDR de la VPC. |
| `availability_zones` | Zonas usadas, en orden. |
| `public_subnet_ids` / `private_subnet_ids` | IDs de las subredes, en el orden de `availability_zones`. |
| `public_subnet_cidrs` / `private_subnet_cidrs` | Rangos de las subredes, en el mismo orden. |
| `public_route_table_id` | Tabla de rutas pública. |
| `private_route_table_ids` | Tablas de rutas privadas, una por zona. |
| `nat_gateway_count` | NAT Gateways creados. |
| `s3_endpoint_id` | Endpoint de S3, o `null`. |
| `flow_logs_log_group_name` | Log group de Flow Logs, o `null`. |

## Pruebas

```bash
cd infra/terraform/modules/network
terraform init -backend=false
terraform test   # proveedor simulado, sin credenciales
```
