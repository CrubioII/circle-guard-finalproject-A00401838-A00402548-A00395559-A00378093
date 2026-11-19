# Módulo de cómputo: clúster Kubernetes ligero (k3s) sobre EC2 — US-20
# Un nodo server con IP elástica y N nodos agent opcionales. Los nodos se
# administran por SSM Session Manager (sin SSH ni llaves .pem), exigen IMDSv2,
# cifran sus discos y descargan imágenes de ECR con su rol IAM.
# El token de unión y el kubeconfig los genera k3s dentro del server y se
# guardan en SSM Parameter Store (SecureString): nunca pasan por Terraform.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# insecure_value: el ID de una AMI pública no es un secreto.
data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

locals {
  base_name  = "${var.name_prefix}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  ami_id              = data.aws_ssm_parameter.ami.insecure_value
  agent_instance_type = coalesce(var.agent_instance_type, var.server_instance_type)

  parameter_prefix     = "/${var.name_prefix}/${var.environment}/k3s"
  token_parameter      = "${local.parameter_prefix}/node-token"
  kubeconfig_parameter = "${local.parameter_prefix}/kubeconfig"
  # Valor inicial no sensible: el server lo reemplaza al arrancar.
  parameter_placeholder = "pendiente-de-arranque"

  managed_policy_arns = concat(
    ["arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"],
    var.enable_ecr_pull ? ["arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"] : [],
    var.enable_cloudwatch_agent ? ["arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"] : [],
    var.additional_iam_policy_arns,
  )

  api_cidrs = distinct(concat([var.vpc_cidr], var.api_allowed_cidrs))

  tags = merge(var.tags, {
    Component = "compute"
    Cluster   = "${local.base_name}-k3s"
  })
}

# -----------------------------------------------------------------------------
# IAM de los nodos
# -----------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${local.base_name}-k3s-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset(local.managed_policy_arns)

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Solo los parámetros del clúster de este ambiente.
resource "aws_iam_role_policy" "k3s_parameters" {
  name = "k3s-cluster-parameters"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadWriteClusterParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.parameter_prefix}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.base_name}-k3s-node"
  role = aws_iam_role.node.name

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Parámetros SSM del clúster
# Terraform los crea con un valor inicial no sensible e ignora los cambios de
# valor: el server los sobrescribe con el token y el kubeconfig reales.
# Así se borran con terraform destroy y el secreto no queda en el estado.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "node_token" {
  name        = local.token_parameter
  description = "Token de unión del clúster k3s de ${var.environment}. Lo escribe el nodo server."
  type        = "SecureString"
  value       = local.parameter_placeholder

  tags = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "kubeconfig" {
  name        = local.kubeconfig_parameter
  description = "Kubeconfig de administración del clúster k3s de ${var.environment}. Lo escribe el nodo server."
  type        = "SecureString"
  tier        = "Intelligent-Tiering"
  value       = local.parameter_placeholder

  tags = local.tags

  lifecycle {
    ignore_changes = [value, tier]
  }
}

# -----------------------------------------------------------------------------
# Security group de los nodos
# Sin SSH: el acceso administrativo es por SSM Session Manager.
# -----------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name        = "${local.base_name}-k3s-nodes"
  description = "Nodos k3s de ${var.environment}: API, Ingress y trafico entre nodos"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, {
    Name = "${local.base_name}-k3s-nodes"
  })
}

resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  security_group_id            = aws_security_group.node.id
  description                  = "Trafico entre nodos del cluster (kubelet, flannel, etcd)"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  for_each = toset(local.api_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "API de Kubernetes"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

resource "aws_vpc_security_group_ingress_rule" "ingress_http" {
  for_each = toset(var.ingress_allowed_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "Ingress HTTP (redireccion a HTTPS)"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "ingress_https" {
  for_each = toset(var.ingress_allowed_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "Ingress HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Salida necesaria para descargar k3s, imágenes y hablar con las APIs de AWS.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "Salida a internet y a las APIs de AWS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# Nodo server
# -----------------------------------------------------------------------------

resource "aws_eip" "server" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.base_name}-k3s-server"
  })
}

resource "aws_launch_template" "server" {
  name_prefix   = "${local.base_name}-k3s-server-"
  image_id      = local.ami_id
  instance_type = var.server_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.node.id]
    subnet_id                   = var.subnet_ids[0]
    delete_on_termination       = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/server.sh.tftpl", {
    name                 = "${local.base_name}-k3s-server"
    environment          = var.environment
    region               = local.region
    k3s_version          = var.k3s_version
    public_ip            = aws_eip.server.public_ip
    token_parameter      = aws_ssm_parameter.node_token.name
    kubeconfig_parameter = aws_ssm_parameter.kubeconfig.name
    node_labels          = var.node_labels
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${local.base_name}-k3s-server"
      Role = "server"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.tags, {
      Name = "${local.base_name}-k3s-server"
    })
  }

  tags = local.tags
}

resource "aws_instance" "server" {
  disable_api_termination = var.enable_termination_protection

  launch_template {
    id      = aws_launch_template.server.id
    version = aws_launch_template.server.latest_version
  }

  # Una AMI nueva no debe reemplazar el nodo en un plan cualquiera:
  # la actualización del sistema se hace de forma explícita.
  lifecycle {
    ignore_changes = [launch_template]
  }

  tags = merge(local.tags, {
    Name = "${local.base_name}-k3s-server"
    Role = "server"
  })

  depends_on = [
    aws_iam_role_policy.k3s_parameters,
    aws_iam_role_policy_attachment.node,
  ]
}

resource "aws_eip_association" "server" {
  allocation_id = aws_eip.server.id
  instance_id   = aws_instance.server.id
}

# -----------------------------------------------------------------------------
# Nodos agent (opcionales)
# -----------------------------------------------------------------------------

resource "aws_launch_template" "agent" {
  count = var.agent_count > 0 ? 1 : 0

  name_prefix   = "${local.base_name}-k3s-agent-"
  image_id      = local.ami_id
  instance_type = local.agent_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  user_data = base64encode(templatefile("${path.module}/templates/agent.sh.tftpl", {
    name              = "${local.base_name}-k3s-agent"
    environment       = var.environment
    region            = local.region
    k3s_version       = var.k3s_version
    server_private_ip = aws_instance.server.private_ip
    token_parameter   = aws_ssm_parameter.node_token.name
    placeholder       = local.parameter_placeholder
    node_labels       = var.node_labels
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${local.base_name}-k3s-agent"
      Role = "agent"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.tags, {
      Name = "${local.base_name}-k3s-agent"
    })
  }

  tags = local.tags
}

resource "aws_instance" "agent" {
  count = var.agent_count

  subnet_id                   = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids      = [aws_security_group.node.id]
  associate_public_ip_address = var.assign_public_ip

  launch_template {
    id      = aws_launch_template.agent[0].id
    version = aws_launch_template.agent[0].latest_version
  }

  lifecycle {
    ignore_changes = [launch_template]
  }

  tags = merge(local.tags, {
    Name = "${local.base_name}-k3s-agent-${count.index + 1}"
    Role = "agent"
  })
}
