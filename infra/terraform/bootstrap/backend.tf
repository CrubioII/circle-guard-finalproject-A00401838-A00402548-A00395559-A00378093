# El estado de este stack también vive en el bucket que crea (clave bootstrap/terraform.tfstate).
# La primera vez no existe el bucket: bootstrap-backend.sh aplica con estado local y
# luego lo migra con terraform init -migrate-state. Después basta con:
#   terraform init -backend-config=backend.hcl   # backend.hcl lo genera init-backend.sh
terraform {
  backend "s3" {}
}
