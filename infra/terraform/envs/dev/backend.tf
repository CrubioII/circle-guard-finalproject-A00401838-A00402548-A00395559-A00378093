# Estado remoto en S3 con bloqueo nativo (use_lockfile), creado por US-36 (infra/terraform/bootstrap).
# La configuración es parcial: los valores se pasan al iniciar para no dejar datos de la cuenta en Git.
#   bash infra/terraform/scripts/init-backend.sh --profile <perfil>   # genera backend.hcl (ignorado por Git)
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
