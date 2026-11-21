# Módulo `compute` — clúster k3s sobre EC2

Crea un clúster Kubernetes ligero ([k3s](https://k3s.io)) en las subredes que recibe:

- un **nodo server** (plano de control y cargas) con **IP elástica**, que no cambia al reiniciar;
- **N nodos agent opcionales**, repartidos entre las subredes, que se unen al server por su IP privada;
- **launch templates** con IMDSv2 obligatorio, disco gp3 cifrado y la AMI Amazon Linux 2023 vigente, leída del parámetro SSM público de AWS;
- un **rol IAM** de los nodos con SSM Session Manager (acceso sin SSH ni llaves `.pem`), lectura de ECR y CloudWatch Agent;
- un **security group** sin SSH: la API `6443` solo desde la VPC y los rangos indicados, `80/443` para el Ingress y tráfico libre entre nodos;
- dos **parámetros SSM SecureString** para el token de unión y el kubeconfig.

## Secretos

El token de unión y el kubeconfig **nunca pasan por Terraform**:

1. Terraform crea los parámetros `/<prefijo>/<env>/k3s/node-token` y `/kubeconfig` con el valor inicial no sensible `pendiente-de-arranque`, e ignora cambios posteriores de valor (`ignore_changes`).
2. Al arrancar, el server genera su token y lo escribe en SSM, leyéndolo directamente del archivo para que no aparezca en la línea de comandos. Publica también un kubeconfig que apunta a la IP elástica.
3. Los agents leen el token con su rol IAM. El rol solo puede leer y escribir los parámetros de su propio clúster.

Así el secreto no queda en el código, en los `tfvars`, en el plan ni en el estado, y `terraform destroy` borra los parámetros.

## Uso

```hcl
module "compute" {
  source = "../../modules/compute"

  environment = "prod"
  vpc_id      = module.network.vpc_id
  vpc_cidr    = module.network.vpc_cidr
  subnet_ids  = module.network.public_subnet_ids

  agent_count                   = 0
  root_volume_size_gb           = 50
  enable_termination_protection = true
}
```

Para obtener el kubeconfig (requiere permisos IAM sobre el parámetro):

```bash
aws ssm get-parameter --name /circleguard/dev/k3s/kubeconfig --with-decryption \
  --query Parameter.Value --output text > ~/.kube/circleguard-dev.yaml
chmod 600 ~/.kube/circleguard-dev.yaml
```

Para abrir una terminal en el server sin SSH: `aws ssm start-session --target <server_instance_id>`.

## Entradas

| Nombre | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `environment` | `string` | — (obligatoria) | `dev`, `stage` o `prod`. |
| `vpc_id` | `string` | — (obligatoria) | VPC de los nodos. |
| `vpc_cidr` | `string` | — (obligatoria) | CIDR de la VPC. Desde él se permite la API. |
| `subnet_ids` | `list(string)` | — (obligatoria) | Subredes. El server usa la primera y los agents se reparten. |
| `name_prefix` | `string` | `"circleguard"` | Prefijo de los recursos. |
| `assign_public_ip` | `bool` | `true` | IP pública en los agents (salida a internet sin NAT). |
| `server_instance_type` | `string` | `"m7i-flex.large"` | Tipo del server. |
| `agent_count` | `number` | `0` | Agents (0 a 10). |
| `agent_instance_type` | `string` | `null` | Tipo de los agents. Con `null` se usa el del server. |
| `root_volume_size_gb` | `number` | `30` | Disco raíz gp3 (20 a 500 GB). |
| `ebs_kms_key_arn` | `string` | `null` | Clave KMS de los discos. Con `null` se usa `aws/ebs`. |
| `ami_ssm_parameter` | `string` | AL2023 x86_64 | Parámetro SSM público con la AMI. |
| `enable_detailed_monitoring` | `bool` | `false` | Métricas de EC2 cada minuto. |
| `enable_termination_protection` | `bool` | `false` | Protección contra terminación del server. |
| `k3s_version` | `string` | `"v1.37.2+k3s1"` | Versión fija de k3s (formato `v1.X.Y+k3sN`). |
| `api_allowed_cidrs` | `list(string)` | `[]` | Rangos externos con acceso a la API. No acepta `0.0.0.0/0`. |
| `ingress_allowed_cidrs` | `list(string)` | `["0.0.0.0/0"]` | Rangos con acceso a 80/443. |
| `node_labels` | `map(string)` | `{}` | Etiquetas de Kubernetes adicionales para los nodos. |
| `enable_ecr_pull` | `bool` | `true` | Política de lectura de ECR. |
| `enable_cloudwatch_agent` | `bool` | `true` | Política de CloudWatch Agent. |
| `additional_iam_policy_arns` | `list(string)` | `[]` | Políticas administradas adicionales. |
| `tags` | `map(string)` | `{}` | Tags adicionales. |

## Salidas

| Nombre | Descripción |
|---|---|
| `cluster_name` | Nombre del clúster (`<prefijo>-<env>-k3s`). |
| `k3s_version` | Versión de k3s. |
| `server_instance_id` | Instancia del server (para SSM Session Manager). |
| `server_private_ip` / `server_public_ip` | IP privada y elástica del server. |
| `api_endpoint` | `https://<ip elástica>:6443`. |
| `agent_instance_ids` | Instancias agent. |
| `node_count` | Nodos en total. |
| `node_security_group_id` | Security group de los nodos. |
| `node_role_arn` / `node_role_name` | Rol IAM de los nodos. |
| `kube_api_allowed_cidrs` | Rangos con acceso a la API. |
| `node_token_parameter_name` / `kubeconfig_parameter_name` | Parámetros SSM del clúster. |

## Notas

- La instancia ignora cambios del launch template (`ignore_changes`), para que una AMI nueva no reemplace el nodo en cualquier `plan`. Actualizar el sistema es una decisión explícita, por ejemplo con `terraform apply -replace`.
- k3s trae Traefik como Ingress y su almacenamiento local. US-21 y US-37 lo usan para el middleware y los servicios.
- El hop limit de IMDSv2 es 2, para que los pods que lo necesiten lleguen a los metadatos a través del nodo.

## Pruebas

```bash
cd infra/terraform/modules/compute
terraform init -backend=false
terraform test   # proveedor simulado, sin credenciales
```
