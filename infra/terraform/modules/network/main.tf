# Módulo de red (Amazon VPC) — US-20
# VPC propia por ambiente con subredes públicas y privadas en varias zonas,
# Internet Gateway, NAT opcional, endpoint gateway de S3 y Flow Logs opcionales.
# El security group por defecto queda sin reglas: todo tráfico debe pasar por
# un security group explícito.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

locals {
  base_name = "${var.name_prefix}-${var.environment}"
  azs       = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Públicas: índices 0..n-1. Privadas: índices 10..10+n-1, con espacio para crecer.
  public_subnets = {
    for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)
  }
  private_subnets = {
    for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + 10)
  }

  nat_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.az_count) : 0

  tags = merge(var.tags, {
    Component = "network"
  })
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${local.base_name}-vpc"
  })

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= var.az_count
      error_message = "La región no tiene ${var.az_count} zonas de disponibilidad disponibles."
    }

    precondition {
      condition     = tonumber(split("/", var.vpc_cidr)[1]) + var.subnet_newbits <= 28
      error_message = "Las subredes quedarían menores que /28 (el mínimo de AWS). Reduce subnet_newbits."
    }
  }
}

# Sin reglas de entrada ni de salida: nadie usa el SG por defecto por accidente.
resource "aws_default_security_group" "this" {
  vpc_id  = aws_vpc.this.id
  ingress = []
  egress  = []

  tags = merge(local.tags, {
    Name = "${local.base_name}-default-sg-locked"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.base_name}-igw"
  })
}

# -----------------------------------------------------------------------------
# Subredes
# Las públicas no asignan IP pública automáticamente: cada instancia decide si
# la necesita (launch template) o usa una IP elástica.
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${local.base_name}-public-${each.key}"
    Tier = "public"
    # Etiqueta que usan los balanceadores de Kubernetes para elegir subredes.
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(local.tags, {
    Name                              = "${local.base_name}-private-${each.key}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# -----------------------------------------------------------------------------
# Rutas
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.base_name}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Una tabla privada por zona, para que cada una pueda usar el NAT de su zona.
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.base_name}-private-rt-${each.key}"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# -----------------------------------------------------------------------------
# NAT Gateway (opcional)
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.base_name}-nat-eip-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[local.azs[count.index]].id

  tags = merge(local.tags, {
    Name = "${local.base_name}-nat-${local.azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat" {
  for_each = var.enable_nat_gateway ? aws_route_table.private : {}

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : index(local.azs, each.key)].id
}

# -----------------------------------------------------------------------------
# Endpoint gateway de S3 (sin costo)
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], [for rt in aws_route_table.private : rt.id])

  tags = merge(local.tags, {
    Name = "${local.base_name}-s3-endpoint"
  })
}

# -----------------------------------------------------------------------------
# VPC Flow Logs (opcional)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/${var.name_prefix}/${var.environment}/vpc-flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.flow_logs_kms_key_arn

  tags = local.tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.base_name}-vpc-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "vpc-flow-logs.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "write-flow-logs"
  role = aws_iam_role.flow_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
      },
    ]
  })
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  tags = merge(local.tags, {
    Name = "${local.base_name}-flow-logs"
  })
}
