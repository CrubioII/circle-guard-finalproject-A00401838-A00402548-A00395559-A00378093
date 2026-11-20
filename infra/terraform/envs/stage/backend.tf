# Estado remoto en S3 con bloqueo en DynamoDB. El bucket y la tabla los crea otra historia.
# La configuración es parcial: los valores se pasan al iniciar para no dejar datos de la cuenta en Git.
#   cp backend.hcl.example backend.hcl   # backend.hcl está ignorado por Git
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
