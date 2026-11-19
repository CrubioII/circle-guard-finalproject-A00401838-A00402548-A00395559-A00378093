# Pruebas del módulo compute con proveedor simulado: no necesitan credenciales AWS.
#   cd infra/terraform/modules/compute && terraform init -backend=false && terraform test

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

  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_eip" {
    defaults = {
      public_ip = "203.0.113.10"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      private_ip = "10.10.0.25"
    }
  }
}

variables {
  environment = "dev"
  vpc_id      = "vpc-0123456789abcdef0"
  vpc_cidr    = "10.10.0.0/16"
  subnet_ids  = ["subnet-aaaa", "subnet-bbbb"]
}

run "crea_un_server_k3s_seguro_con_ip_elastica" {
  command = plan

  assert {
    condition     = aws_launch_template.server.image_id == "ami-0123456789abcdef0" && aws_launch_template.server.instance_type == "m7i-flex.large"
    error_message = "El server debe usar la AMI del parámetro SSM y m7i-flex.large por defecto."
  }

  assert {
    condition     = aws_launch_template.server.metadata_options[0].http_tokens == "required"
    error_message = "Los nodos deben exigir IMDSv2."
  }

  assert {
    condition     = aws_launch_template.server.block_device_mappings[0].ebs[0].encrypted == "true" && aws_launch_template.server.block_device_mappings[0].ebs[0].volume_type == "gp3"
    error_message = "El disco raíz debe ser gp3 y estar cifrado."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.server.user_data), "INSTALL_K3S_VERSION=\"v1.37.2+k3s1\"")
    error_message = "El arranque debe instalar la versión fija de k3s."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.server.user_data), "--tls-san \"$${PUBLIC_IP}\"") && strcontains(base64decode(aws_launch_template.server.user_data), "PUBLIC_IP=\"203.0.113.10\"")
    error_message = "El certificado de la API debe incluir la IP elástica."
  }

  assert {
    condition     = output.api_endpoint == "https://203.0.113.10:6443"
    error_message = "El endpoint de la API debe usar la IP elástica."
  }

  assert {
    condition     = length(aws_instance.agent) == 0 && output.node_count == 1
    error_message = "Por defecto el clúster debe tener un solo nodo."
  }

  assert {
    condition     = output.kube_api_allowed_cidrs == tolist(["10.10.0.0/16"])
    error_message = "Sin api_allowed_cidrs la API solo debe aceptar tráfico de la VPC."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.kube_api : r.from_port == 6443])
    error_message = "La regla de la API debe abrir solo el puerto 6443."
  }

  assert {
    condition     = aws_ssm_parameter.node_token.type == "SecureString" && aws_ssm_parameter.node_token.name == "/circleguard/dev/k3s/node-token"
    error_message = "El token de unión debe guardarse como SecureString bajo /circleguard/dev/k3s/."
  }

  assert {
    condition     = aws_ssm_parameter.node_token.value == "pendiente-de-arranque"
    error_message = "Terraform solo debe conocer el valor inicial no sensible del token."
  }

  assert {
    condition     = contains(keys(aws_iam_role_policy_attachment.node), "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore") && contains(keys(aws_iam_role_policy_attachment.node), "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly")
    error_message = "El rol de los nodos debe permitir SSM Session Manager y descargar imágenes de ECR."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.k3s_parameters.policy, "parameter/circleguard/dev/k3s/*")
    error_message = "Los nodos solo deben acceder a los parámetros de su propio clúster."
  }
}

run "agrega_agents_repartidos_en_las_subredes" {
  command = plan

  variables {
    agent_count         = 3
    agent_instance_type = "t3.large"
    api_allowed_cidrs   = ["198.51.100.0/24"]
  }

  assert {
    condition     = length(aws_instance.agent) == 3 && output.node_count == 4
    error_message = "Deben existir 3 agents y 4 nodos en total."
  }

  assert {
    condition     = [for a in aws_instance.agent : a.subnet_id] == ["subnet-aaaa", "subnet-bbbb", "subnet-aaaa"]
    error_message = "Los agents deben repartirse entre las subredes."
  }

  assert {
    condition     = aws_launch_template.agent[0].instance_type == "t3.large"
    error_message = "Los agents deben usar agent_instance_type."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.agent[0].user_data), "SERVER_URL=\"https://10.10.0.25:6443\"")
    error_message = "Los agents deben unirse al server por su IP privada."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.kube_api) == 2
    error_message = "La API debe aceptar la VPC y el rango de administración indicado."
  }
}

run "prod_protege_el_server_contra_terminacion" {
  command = plan

  variables {
    environment                   = "prod"
    enable_termination_protection = true
    enable_detailed_monitoring    = true
    root_volume_size_gb           = 50
  }

  assert {
    condition     = aws_instance.server.disable_api_termination
    error_message = "En prod el server debe tener protección contra terminación."
  }

  assert {
    condition     = aws_launch_template.server.block_device_mappings[0].ebs[0].volume_size == 50
    error_message = "El disco debe usar el tamaño indicado."
  }
}

run "rechaza_abrir_la_api_a_internet" {
  command = plan

  variables {
    api_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "rechaza_versiones_de_k3s_mal_formadas" {
  command = plan

  variables {
    k3s_version = "latest"
  }

  expect_failures = [var.k3s_version]
}

run "rechaza_demasiados_agents" {
  command = plan

  variables {
    agent_count = 11
  }

  expect_failures = [var.agent_count]
}
