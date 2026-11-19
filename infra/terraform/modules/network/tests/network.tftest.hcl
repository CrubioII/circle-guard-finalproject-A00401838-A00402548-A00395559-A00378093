# Pruebas del módulo network con proveedor simulado: no necesitan credenciales AWS.
#   cd infra/terraform/modules/network && terraform init -backend=false && terraform test

mock_provider "aws" {
  # Los valores simulados se usan ya en el plan (Terraform >= 1.11).
  override_during = plan

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-2a", "us-east-2b", "us-east-2c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
    }
  }
}

variables {
  environment = "dev"
  vpc_cidr    = "10.10.0.0/16"
}

run "crea_vpc_con_subredes_publicas_y_privadas_en_dos_zonas" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.10.0.0/16" && aws_vpc.this.enable_dns_hostnames
    error_message = "La VPC debe usar el CIDR indicado y tener DNS habilitado."
  }

  assert {
    condition     = tolist(output.availability_zones) == tolist(["us-east-2a", "us-east-2b"])
    error_message = "Por defecto la red debe usar las dos primeras zonas."
  }

  assert {
    condition     = tolist(output.public_subnet_cidrs) == tolist(["10.10.0.0/24", "10.10.1.0/24"])
    error_message = "Las subredes públicas deben ser 10.10.0.0/24 y 10.10.1.0/24."
  }

  assert {
    condition     = tolist(output.private_subnet_cidrs) == tolist(["10.10.10.0/24", "10.10.11.0/24"])
    error_message = "Las subredes privadas deben ser 10.10.10.0/24 y 10.10.11.0/24."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch])
    error_message = "Las subredes públicas no deben asignar IP pública automáticamente."
  }

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "El security group por defecto debe quedar sin reglas."
  }

  assert {
    condition     = aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "La tabla pública debe salir a internet por el Internet Gateway."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_route.private_nat) == 0
    error_message = "Sin enable_nat_gateway no debe crearse NAT ni ruta privada a internet."
  }

  assert {
    condition     = aws_vpc_endpoint.s3[0].service_name == "com.amazonaws.us-east-2.s3" && aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway"
    error_message = "Debe existir el endpoint gateway de S3 de la región."
  }

  assert {
    condition     = length(aws_flow_log.this) == 0
    error_message = "Los Flow Logs deben estar desactivados por defecto."
  }
}

run "un_solo_nat_para_todas_las_zonas" {
  command = plan

  variables {
    enable_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_route.private_nat) == 2
    error_message = "Con single_nat_gateway debe existir un NAT y una ruta por tabla privada."
  }
}

run "un_nat_por_zona_y_flow_logs_en_prod" {
  command = plan

  variables {
    environment              = "prod"
    vpc_cidr                 = "10.30.0.0/16"
    az_count                 = 3
    enable_nat_gateway       = true
    single_nat_gateway       = false
    enable_flow_logs         = true
    flow_logs_retention_days = 90
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3 && output.nat_gateway_count == 3
    error_message = "Sin single_nat_gateway debe existir un NAT por zona."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].name == "/circleguard/prod/vpc-flow-logs" && aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 90
    error_message = "Los Flow Logs deben ir a /circleguard/prod/vpc-flow-logs con la retención indicada."
  }

  assert {
    condition     = aws_flow_log.this[0].traffic_type == "ALL"
    error_message = "Los Flow Logs deben registrar todo el tráfico."
  }
}

run "rechaza_cidr_invalido" {
  command = plan

  variables {
    vpc_cidr = "10.10.0.0/8"
  }

  expect_failures = [var.vpc_cidr]
}

run "rechaza_mas_de_tres_zonas" {
  command = plan

  variables {
    az_count = 4
  }

  expect_failures = [var.az_count]
}
