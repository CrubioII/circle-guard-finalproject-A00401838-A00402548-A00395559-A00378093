# Configuración mínima para probar el bloqueo del estado remoto (US-36, CA2).
# No crea nada en AWS: solo un time_sleep que mantiene el apply abierto y un
# terraform_data que deja constancia de qué ejecución escribió el estado.
# La usa scripts/test-state-lock.sh con la clave tests/state-lock/terraform.tfstate.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12, < 1.0"
    }
  }

  backend "s3" {}
}

variable "run_label" {
  description = "Nombre de la ejecución (A, B, ...)."
  type        = string
}

variable "hold_seconds" {
  description = "Segundos que el apply mantiene el bloqueo."
  type        = number
  default     = 45
}

resource "time_sleep" "hold_lock" {
  create_duration = "${var.hold_seconds}s"

  # Un valor nuevo en cada ejecución obliga a recrear el recurso y a esperar otra vez.
  triggers = {
    run = var.run_label
  }
}

resource "terraform_data" "writer" {
  input = {
    run_label = var.run_label
  }

  depends_on = [time_sleep.hold_lock]
}

output "last_writer" {
  description = "Ejecución que aplicó por última vez."
  value       = terraform_data.writer.output.run_label
}
