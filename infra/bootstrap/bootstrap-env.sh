#!/usr/bin/env bash
# =============================================================================
# Script Bash idempotente para aprovisionar entornos aislados (dev, stage, prod)
# y externalizar secretos — CircleGuard (US-05 / SCRUM-17 / SCRUM-43 / SCRUM-44 / SCRUM-45)
#
# Uso en la máquina destino del ambiente:
#   sudo bash infra/bootstrap/bootstrap-env.sh dev
#   sudo bash infra/bootstrap/bootstrap-env.sh stage
#   sudo bash infra/bootstrap/bootstrap-env.sh prod
#
# Uso desde estación de trabajo o Jenkins hacia AWS EC2 (Región seleccionada us-east-2):
#   bash infra/bootstrap/bootstrap-env.sh all --provision-aws --aws-profile personal --aws-region us-east-2
#   bash infra/bootstrap/bootstrap-env.sh dev --provision-aws --aws-profile personal --aws-region us-east-2
#
# Garantías de idempotencia (CA1, CA2, CA3):
#   - Banderas de seguridad estrictas: set -euo pipefail
#   - Crea y aísla Security Groups e instancias EC2 por ambiente (dev, stage, prod) sin duplicar
#   - Configura Docker, red aislada circleguard_<env>_net, /etc/docker/daemon.json y login al registro
#   - Crea la jerarquía /opt/circleguard/<env>/{compose,config,logs,backups}
#   - Externaliza credenciales en /opt/circleguard/<env>/.env (permisos 0600) sin exponerlas en Git
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TARGET_ENV=""
REGISTRY_URL="${REGISTRY_URL:-18.117.90.15:5000}"
REGISTRY_INSECURE="${REGISTRY_INSECURE:-true}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
DEPLOY_BASE_DIR="${DEPLOY_BASE_DIR:-/opt/circleguard}"
DEPLOY_USER="${DEPLOY_USER:-${SUDO_USER:-${USER:-ec2-user}}}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
START_MIDDLEWARE="${START_MIDDLEWARE:-false}"
DRY_RUN="${DRY_RUN:-false}"
STATE_ROOT="${STATE_ROOT:-}"

# Parámetros AWS EC2 (Región seleccionada del proyecto)
PROVISION_AWS="${PROVISION_AWS:-false}"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-personal}"
AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-2}"
EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-m7i-flex.large}"
EC2_AMI_ID="${EC2_AMI_ID:-ami-02dae70ab25064279}"
EC2_KEY_NAME="${EC2_KEY_NAME:-proyectoIngeClave}"
EC2_SSH_KEY_PATH="${EC2_SSH_KEY_PATH:-${REPO_ROOT}/proyectoIngeClave.pem}"
EC2_SSH_USER="${EC2_SSH_USER:-ec2-user}"
EC2_VOLUME_SIZE_GB="${EC2_VOLUME_SIZE_GB:-20}"

log_info()  { printf '[bootstrap-env][INFO]  %s\n' "$*"; }
log_ok()    { printf '[bootstrap-env][OK]    %s\n' "$*"; }
log_warn()  { printf '[bootstrap-env][WARN]  %s\n' "$*" >&2; }
log_error() { printf '[bootstrap-env][ERROR] %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Uso: infra/bootstrap/bootstrap-env.sh <dev|stage|prod|all> [opciones]

Argumentos y opciones:
  <dev|stage|prod|all>         Ambiente objetivo (o --env <dev|stage|prod|all>)
  --env <dev|stage|prod|all>   Ambiente objetivo
  --registry-url <host:port>   URL del registro privado de imágenes (por defecto: 18.117.90.15:5000)
  --registry-user <usuario>    Usuario para docker login en el registro privado
  --registry-password <pass>   Contraseña para docker login en el registro privado
  --deploy-base-dir <ruta>     Directorio base de despliegue (por defecto: /opt/circleguard)
  --start-middleware           Levanta el stack de middleware del ambiente tras configurar
  --state-dir <directorio>     Prefijo de estado aislado para pruebas de idempotencia
  --dry-run                    Valida prerrequisitos e idempotencia sin mutar demonios del host

Opciones de aprovisionamiento en nube (AWS EC2 en la Región seleccionada):
  --provision-aws              Aprovisiona/reconcilia SG + instancia EC2 aislada por ambiente
  --aws-profile <perfil>       Perfil de AWS CLI (por defecto: personal)
  --aws-region <región>        Región seleccionada en AWS (por defecto: us-east-2)
  --instance-type <tipo>       Tipo de instancia EC2 (por defecto: t3.small)
  --ssh-key-path <ruta>        Ruta a la llave privada SSH (por defecto: ./proyectoIngeClave.pem)
  -h, --help                   Muestra esta ayuda
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            dev|stage|prod|all)
                TARGET_ENV="$1"
                shift
                ;;
            --env)
                TARGET_ENV="${2:?Falta valor para --env}"
                shift 2
                ;;
            --registry-url)
                REGISTRY_URL="${2:?Falta valor para --registry-url}"
                shift 2
                ;;
            --registry-user)
                REGISTRY_USER="${2:-}"
                shift 2
                ;;
            --registry-password)
                REGISTRY_PASSWORD="${2:-}"
                shift 2
                ;;
            --deploy-base-dir)
                DEPLOY_BASE_DIR="${2:?Falta valor para --deploy-base-dir}"
                shift 2
                ;;
            --start-middleware)
                START_MIDDLEWARE="true"
                shift
                ;;
            --state-dir)
                STATE_ROOT="${2:?Falta valor para --state-dir}"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --provision-aws)
                PROVISION_AWS="true"
                shift
                ;;
            --aws-profile)
                AWS_PROFILE_NAME="${2:?Falta valor para --aws-profile}"
                shift 2
                ;;
            --aws-region)
                AWS_REGION_NAME="${2:?Falta valor para --aws-region}"
                shift 2
                ;;
            --instance-type)
                EC2_INSTANCE_TYPE="${2:?Falta valor para --instance-type}"
                shift 2
                ;;
            --ssh-key-path)
                EC2_SSH_KEY_PATH="${2:?Falta valor para --ssh-key-path}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Opción o argumento no reconocido: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$TARGET_ENV" in
        dev|stage|prod) ;;
        all)
            if [[ "$PROVISION_AWS" != "true" ]] && [[ -z "$STATE_ROOT" ]] && [[ "$DRY_RUN" != "true" ]]; then
                log_error "El modo 'all' en ejecución local requiere --provision-aws, --state-dir o --dry-run."
                exit 1
            fi
            ;;
        *)
            log_error "Debe especificar un ambiente válido: dev, stage o prod (recibido: '${TARGET_ENV}')."
            usage
            exit 1
            ;;
    esac
}

run_privileged() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] $*"
        return 0
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        log_error "Se requieren privilegios de superusuario (root o sudo) para ejecutar: $*"
        return 1
    fi
}

run_docker() {
    if docker info >/dev/null 2>&1; then
        docker "$@"
    else
        run_privileged docker "$@"
    fi
}

# -----------------------------------------------------------------------------
# Aprovisionamiento idempotente de un ambiente aislado (dev, stage o prod) en AWS EC2
# -----------------------------------------------------------------------------
provision_single_aws_env() {
    local env_name="$1"
    local sg_name="circleguard-${env_name}-sg"
    local instance_name="circleguard-env-${env_name}"

    log_info "=== Aprovisionando entorno aislado '${env_name}' en AWS EC2 (${AWS_REGION_NAME}) ==="

    if [[ ! -f "$EC2_SSH_KEY_PATH" ]]; then
        log_error "No se encontró la llave SSH en ${EC2_SSH_KEY_PATH}."
        exit 1
    fi

    local vpc_id
    vpc_id="$(aws ec2 describe-vpcs \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --filters "Name=isDefault,Values=true" \
        --query "Vpcs[0].VpcId" \
        --output text)"

    if [[ -z "$vpc_id" ]] || [[ "$vpc_id" == "None" ]]; then
        vpc_id="$(aws ec2 describe-vpcs \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --query "Vpcs[0].VpcId" \
            --output text)"
    fi

    # 1. Security Group dedicado por ambiente (aislamiento de red entre dev, stage y prod)
    local sg_id
    sg_id="$(aws ec2 describe-security-groups \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --filters "Name=group-name,Values=${sg_name}" "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>/dev/null || echo "None")"

    if [[ -z "$sg_id" ]] || [[ "$sg_id" == "None" ]]; then
        log_info "Creando Security Group aislado '${sg_name}' para el ambiente '${env_name}'..."
        sg_id="$(aws ec2 create-security-group \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --group-name "$sg_name" \
            --description "Security Group aislado para CircleGuard ambiente ${env_name} (US-05)" \
            --vpc-id "$vpc_id" \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${sg_name}},{Key=Environment,Value=${env_name}},{Key=Project,Value=CircleGuard},{Key=UserStory,Value=US-05}]" \
            --query "GroupId" \
            --output text)"
        log_ok "Security Group '${sg_name}' creado: ${sg_id}"
    else
        log_ok "Security Group '${sg_name}' ya existe (${sg_id}); reutilizando de forma idempotente."
    fi

    # Puertos expuestos por ambiente: 22 (SSH desde Jenkins), 8080 (Web), 8180 (Auth), 8087 (Gateway)
    for port in 22 8080 8180 8087; do
        local exists_rule
        exists_rule="$(aws ec2 describe-security-groups \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --group-ids "$sg_id" \
            --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\` && ToPort==\`${port}\`].FromPort" \
            --output text 2>/dev/null || true)"
        if [[ -n "$exists_rule" ]] && [[ "$exists_rule" != "None" ]]; then
            log_ok "[${env_name}] Regla TCP/${port} ya autorizada en ${sg_id}."
        else
            aws ec2 authorize-security-group-ingress \
                --profile "$AWS_PROFILE_NAME" \
                --region "$AWS_REGION_NAME" \
                --group-id "$sg_id" \
                --protocol tcp \
                --port "$port" \
                --cidr "0.0.0.0/0" >/dev/null
            log_ok "[${env_name}] Regla TCP/${port} agregada a ${sg_id}."
        fi
    done

    # 2. Instancia EC2 dedicada por ambiente (circleguard-env-dev, circleguard-env-stage, circleguard-env-prod)
    local instance_id
    instance_id="$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --filters "Name=tag:Name,Values=${instance_name}" "Name=instance-state-name,Values=pending,running" \
        --query "Reservations[].Instances[0].InstanceId | [0]" \
        --output text 2>/dev/null || echo "None")"

    if [[ -z "$instance_id" ]] || [[ "$instance_id" == "None" ]]; then
        instance_id="$(aws ec2 describe-instances \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --filters "Name=tag:IsolatedEnv_${env_name},Values=true" "Name=instance-state-name,Values=pending,running" \
            --query "Reservations[].Instances[0].InstanceId | [0]" \
            --output text 2>/dev/null || echo "None")"
    fi

    if [[ -z "$instance_id" ]] || [[ "$instance_id" == "None" ]]; then
        log_info "Lanzando instancia EC2 aislada '${instance_name}' (${EC2_INSTANCE_TYPE}, ${EC2_VOLUME_SIZE_GB} GB gp3)..."
        local run_output=""
        if run_output="$(aws ec2 run-instances \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --image-id "$EC2_AMI_ID" \
            --instance-type "$EC2_INSTANCE_TYPE" \
            --key-name "$EC2_KEY_NAME" \
            --security-group-ids "$sg_id" \
            --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${EC2_VOLUME_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true}" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${instance_name}},{Key=Environment,Value=${env_name}},{Key=IsolatedEnv_${env_name},Value=true},{Key=Project,Value=CircleGuard},{Key=UserStory,Value=US-05}]" \
            --query "Instances[0].InstanceId" \
            --output text 2>&1)"; then
            instance_id="$run_output"
            log_ok "Instancia '${instance_name}' creada: ${instance_id}. Esperando estado 'running'..."
            aws ec2 wait instance-running \
                --profile "$AWS_PROFILE_NAME" \
                --region "$AWS_REGION_NAME" \
                --instance-ids "$instance_id"
        elif printf '%s' "$run_output" | grep -q "VcpuLimitExceeded"; then
            log_warn "[${env_name}] Cuota máxima de 8 vCPUs alcanzada en el proyecto AWS Free Tier. Asignando entorno aislado '${env_name}' (red Docker circleguard_${env_name}_net, directorio /opt/circleguard/${env_name} y SG ${sg_id}) sobre nodo de ambientes existente..."
            instance_id="$(aws ec2 describe-instances \
                --profile "$AWS_PROFILE_NAME" \
                --region "$AWS_REGION_NAME" \
                --filters "Name=tag:Project,Values=CircleGuard" "Name=tag:UserStory,Values=US-05" "Name=instance-state-name,Values=running" \
                --query "Reservations[].Instances[0].InstanceId | [0]" \
                --output text)"
            # Asociar también el Security Group aislado del ambiente y etiquetar para idempotencia
            local current_sgs
            current_sgs="$(aws ec2 describe-instances \
                --profile "$AWS_PROFILE_NAME" \
                --region "$AWS_REGION_NAME" \
                --instance-ids "$instance_id" \
                --query "Reservations[0].Instances[0].SecurityGroups[].GroupId" \
                --output text)"
            # shellcheck disable=SC2086
            aws ec2 modify-instance-attribute \
                --profile "$AWS_PROFILE_NAME" \
                --region "$AWS_REGION_NAME" \
                --instance-id "$instance_id" \
                --groups $current_sgs "$sg_id"
            aws ec2 create-tags \
                --profile "$AWS_PROFILE_NAME" \
                --region "$AWS_REGION_NAME" \
                --resources "$instance_id" \
                --tags "Key=IsolatedEnv_${env_name},Value=true"
            log_ok "[${env_name}] Nodo ${instance_id} etiquetado con IsolatedEnv_${env_name}=true y asociado a ${sg_id}."
        else
            log_error "Fallo al crear instancia '${instance_name}': ${run_output}"
            exit 1
        fi
    else
        log_ok "Instancia para el ambiente '${env_name}' ya existe (${instance_id}); reutilizando sin duplicar recursos."
    fi

    local public_ip private_ip
    public_ip="$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)"
    private_ip="$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text)"
    log_ok "[${env_name}] Instancia ${instance_id} activa (IP pública=${public_ip}, IP privada=${private_ip})."

    # 3. Esperar disponibilidad SSH
    log_info "[${env_name}] Esperando conectividad SSH hacia ${EC2_SSH_USER}@${public_ip}..."
    local ssh_ready="false"
    for _ in $(seq 1 30); do
        if ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${EC2_SSH_USER}@${public_ip}" "echo ok" >/dev/null 2>&1; then
            ssh_ready="true"
            break
        fi
        sleep 5
    done
    if [[ "$ssh_ready" != "true" ]]; then
        log_error "[${env_name}] No se logró establecer conexión SSH con ${public_ip}."
        exit 1
    fi
    log_ok "[${env_name}] Conectividad SSH verificada con ${public_ip}."

    # 4. Sincronizar artefactos de bootstrap al nodo remoto
    local remote_src="/opt/circleguard-bootstrap"
    ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no "${EC2_SSH_USER}@${public_ip}" \
        "sudo mkdir -p '${remote_src}' && sudo chown -R ${EC2_SSH_USER}:${EC2_SSH_USER} '${remote_src}'"

    COPYFILE_DISABLE=1 tar --no-xattrs -C "$REPO_ROOT" -czf - \
        docker-compose.dev.yml \
        deploy/compose \
        init-db.sql \
        .env.example \
        infra/bootstrap \
        2>/dev/null \
        | ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no "${EC2_SSH_USER}@${public_ip}" \
            "tar -C '${remote_src}' -xzf -"

    # 5. Ejecutar bootstrap-env.sh localmente dentro de la máquina del ambiente
    log_info "[${env_name}] Ejecutando bootstrap-env.sh en ${public_ip}..."
    ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no "${EC2_SSH_USER}@${public_ip}" \
        "sudo DEPLOY_USER='${EC2_SSH_USER}' PUBLIC_HOST='${public_ip}' bash '${remote_src}/infra/bootstrap/bootstrap-env.sh' '${env_name}' --registry-url '${REGISTRY_URL}'"
}

# -----------------------------------------------------------------------------
# CA1: Configuración idempotente de sistema, swap, Docker, red, directorios y registro
# -----------------------------------------------------------------------------
configure_host_kernel_and_swap() {
    local env_name="$1"
    local sysctl_file="${STATE_ROOT}/etc/sysctl.d/99-circleguard-${env_name}.conf"
    local fstab_file="${STATE_ROOT}/etc/fstab"

    local desired_sysctl
    desired_sysctl="$(cat <<EOF
# Generado de forma idempotente por infra/bootstrap/bootstrap-env.sh (US-05, env=${env_name})
vm.max_map_count = 262144
fs.file-max = 131072
EOF
)"

    if [[ -n "$STATE_ROOT" ]]; then
        mkdir -p "$(dirname "$sysctl_file")" "$(dirname "$fstab_file")"
        if [[ -f "$sysctl_file" ]] && [[ "$(cat "$sysctl_file")" == "$desired_sysctl" ]]; then
            log_ok "[${env_name}] Archivo sysctl (${sysctl_file}) ya actualizado (idempotente)."
        else
            printf '%s\n' "$desired_sysctl" > "$sysctl_file"
            log_ok "[${env_name}] Archivo sysctl escrito en ${sysctl_file}."
        fi

        touch "$fstab_file"
        if grep -q '^/swapfile ' "$fstab_file" 2>/dev/null; then
            log_ok "[${env_name}] Swap ya registrado en ${fstab_file} (sin duplicar)."
        else
            printf '/swapfile none swap sw 0 0\n' >> "$fstab_file"
            log_ok "[${env_name}] Swap registrado en ${fstab_file}."
        fi
        return 0
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_info "[${env_name}] Entorno $(uname -s) detectado; omitiendo ajustes de kernel Linux directos."
        return 0
    fi

    if [[ -f "$sysctl_file" ]] && [[ "$(cat "$sysctl_file" 2>/dev/null || true)" == "$desired_sysctl" ]]; then
        log_ok "[${env_name}] Persistencia sysctl en ${sysctl_file} ya configurada (idempotente)."
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Escribir ${sysctl_file} y aplicar sysctl -p"
        else
            printf '%s\n' "$desired_sysctl" | run_privileged tee "$sysctl_file" >/dev/null
            run_privileged sysctl -p "$sysctl_file" >/dev/null
            log_ok "[${env_name}] Parámetros sysctl aplicados en ${sysctl_file}."
        fi
    fi

    if [[ "${SWAP_SIZE_MB}" -gt 0 ]]; then
        if swapon --show 2>/dev/null | grep -q '/'; then
            log_ok "[${env_name}] Swap ya se encuentra activa en el sistema (idempotente)."
        elif [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Crear y activar /swapfile de ${SWAP_SIZE_MB} MB"
        else
            if [[ ! -f /swapfile ]]; then
                run_privileged dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}" status=none
                run_privileged chmod 600 /swapfile
                run_privileged mkswap /swapfile >/dev/null
            fi
            run_privileged swapon /swapfile
            if ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
                printf '/swapfile none swap sw 0 0\n' | run_privileged tee -a /etc/fstab >/dev/null
            fi
            log_ok "[${env_name}] Swap de ${SWAP_SIZE_MB} MB habilitada y persistida en /etc/fstab."
        fi
    fi
}

install_docker_and_packages() {
    local env_name="$1"
    log_info "[${env_name}] Verificando paquetes base, Docker Engine y Docker Compose v2..."

    local missing_pkgs=()
    for cmd in curl git jq unzip tar openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_pkgs+=("$cmd")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        log_ok "[${env_name}] Paquetes base (curl, git, jq, unzip, tar, openssl) ya instalados."
    elif [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Instalar paquetes faltantes: ${missing_pkgs[*]}"
    elif command -v apt-get >/dev/null 2>&1; then
        run_privileged apt-get update -y
        run_privileged apt-get install -y --no-install-recommends ca-certificates gnupg "${missing_pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        run_privileged dnf install -y ca-certificates "${missing_pkgs[@]}"
    elif command -v yum >/dev/null 2>&1; then
        run_privileged yum install -y ca-certificates "${missing_pkgs[@]}"
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_ok "[${env_name}] Docker y Docker Compose v2 ya están instalados."
    elif [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Instalar Docker Engine y Docker Compose v2"
    elif command -v dnf >/dev/null 2>&1; then
        if ! command -v docker >/dev/null 2>&1; then
            run_privileged dnf install -y docker
        fi
        if ! docker compose version >/dev/null 2>&1; then
            run_privileged mkdir -p /usr/local/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins
            local arch
            arch="$(uname -m)"
            run_privileged curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-${arch}" \
                -o /usr/local/lib/docker/cli-plugins/docker-compose
            run_privileged chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
            run_privileged cp -f /usr/local/lib/docker/cli-plugins/docker-compose /usr/libexec/docker/cli-plugins/docker-compose
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        run_privileged apt-get update -y
        run_privileged apt-get install -y --no-install-recommends docker.io docker-compose-v2 || \
            run_privileged apt-get install -y --no-install-recommends docker.io
    fi

    if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            log_ok "[${env_name}] Servicio systemd 'docker' ya se encuentra activo."
        else
            run_privileged systemctl enable --now docker
            log_ok "[${env_name}] Servicio systemd 'docker' habilitado e iniciado."
        fi
    fi

    if [[ "$(uname -s)" == "Linux" ]] && [[ -n "$DEPLOY_USER" ]] && [[ "$DEPLOY_USER" != "root" ]]; then
        if id -nG "$DEPLOY_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "docker"; then
            log_ok "[${env_name}] Usuario '${DEPLOY_USER}' ya pertenece al grupo 'docker'."
        else
            run_privileged usermod -aG docker "$DEPLOY_USER"
            log_ok "[${env_name}] Usuario '${DEPLOY_USER}' agregado al grupo 'docker'."
        fi
    fi
}

configure_registry_and_login() {
    local env_name="$1"
    local daemon_json="${STATE_ROOT}/etc/docker/daemon.json"

    local desired_daemon_json
    desired_daemon_json="$(cat <<EOF
{
  "insecure-registries": ["${REGISTRY_URL}"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
)"

    if [[ -n "$STATE_ROOT" ]]; then
        mkdir -p "$(dirname "$daemon_json")"
        if [[ -f "$daemon_json" ]] && [[ "$(cat "$daemon_json")" == "$desired_daemon_json" ]]; then
            log_ok "[${env_name}] Configuración de registro en ${daemon_json} ya actualizada (idempotente)."
        else
            printf '%s\n' "$desired_daemon_json" > "$daemon_json"
            log_ok "[${env_name}] Configuración de registro escrita en ${daemon_json}."
        fi
        return 0
    fi

    if [[ "$(uname -s)" == "Linux" ]]; then
        if [[ -f "$daemon_json" ]] && [[ "$(cat "$daemon_json" 2>/dev/null || true)" == "$desired_daemon_json" ]]; then
            log_ok "[${env_name}] /etc/docker/daemon.json ya tiene configurado el registro ${REGISTRY_URL} (idempotente)."
        elif [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Actualizar /etc/docker/daemon.json con insecure-registries=[${REGISTRY_URL}] y recargar docker"
        else
            run_privileged mkdir -p /etc/docker
            printf '%s\n' "$desired_daemon_json" | run_privileged tee "$daemon_json" >/dev/null
            if command -v systemctl >/dev/null 2>&1; then
                run_privileged systemctl restart docker
            fi
            log_ok "[${env_name}] /etc/docker/daemon.json configurado con registro ${REGISTRY_URL}."
        fi
    fi

    if [[ -n "$REGISTRY_USER" ]] && [[ -n "$REGISTRY_PASSWORD" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] docker login ${REGISTRY_URL} -u ${REGISTRY_USER} --password-stdin"
        else
            printf '%s\n' "$REGISTRY_PASSWORD" | run_docker login "$REGISTRY_URL" -u "$REGISTRY_USER" --password-stdin >/dev/null
            log_ok "[${env_name}] Sesión iniciada en registro privado ${REGISTRY_URL}."
        fi
    else
        log_info "[${env_name}] Credenciales REGISTRY_USER/REGISTRY_PASSWORD no suministradas en esta corrida; registro ${REGISTRY_URL} listo en daemon.json."
    fi
}

prepare_isolated_directories_and_secrets() {
    local env_name="$1"
    local base_dir="${STATE_ROOT}${DEPLOY_BASE_DIR}/${env_name}"
    local net_name="circleguard_${env_name}_net"
    # US-08: pila completa del ambiente (middleware + 5 servicios núcleo + web). Aquí solo se
    # copia y valida; levantarla corresponde al pipeline de despliegue (US-13).
    local stack_file="docker-compose.${env_name}.yml"

    log_info "[${env_name}] Preparando estructura de directorios aislados en ${base_dir}..."

    if [[ -n "$STATE_ROOT" ]]; then
        mkdir -p "${base_dir}/compose/stack" "${base_dir}/config" "${base_dir}/logs" "${base_dir}/backups"
        chmod 750 "$base_dir"
        cp -f "${REPO_ROOT}/docker-compose.dev.yml" "${base_dir}/compose/docker-compose.dev.yml"
        cp -f "${REPO_ROOT}/init-db.sql" "${base_dir}/compose/init-db.sql"
        cp -f "${REPO_ROOT}/deploy/compose/${stack_file}" "${base_dir}/compose/stack/${stack_file}"
        cp -f "${SCRIPT_DIR}/env/.env.${env_name}.example" "${base_dir}/config/.env.example"
        INIT_DB_SCRIPT="${base_dir}/compose/init-db.sql" PUBLIC_HOST="${PUBLIC_HOST:-localhost}" \
        bash "${SCRIPT_DIR}/inject-jenkins-secrets.sh" \
            --env "$env_name" \
            --output "${base_dir}/.env" \
            --registry-url "$REGISTRY_URL"
        log_ok "[${env_name}] Directorios y archivo de secretos ${base_dir}/.env listos."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Crear ${base_dir}/{compose,config,logs,backups}, red Docker ${net_name} y generar ${base_dir}/.env (0600)"
        return 0
    fi

    run_privileged mkdir -p "${base_dir}/compose/stack" "${base_dir}/config" "${base_dir}/logs" "${base_dir}/backups"
    run_privileged chmod 750 "$base_dir"
    run_privileged cp -f "${REPO_ROOT}/docker-compose.dev.yml" "${base_dir}/compose/docker-compose.dev.yml"
    run_privileged cp -f "${REPO_ROOT}/init-db.sql" "${base_dir}/compose/init-db.sql"
    run_privileged cp -f "${REPO_ROOT}/deploy/compose/${stack_file}" "${base_dir}/compose/stack/${stack_file}"
    run_privileged cp -f "${SCRIPT_DIR}/env/.env.${env_name}.example" "${base_dir}/config/.env.example"

    # 'env' explícito: sudo descarta las variables de entorno del llamador.
    run_privileged env INIT_DB_SCRIPT="${base_dir}/compose/init-db.sql" PUBLIC_HOST="${PUBLIC_HOST:-localhost}" \
        bash "${SCRIPT_DIR}/inject-jenkins-secrets.sh" \
        --env "$env_name" \
        --output "${base_dir}/.env" \
        --registry-url "$REGISTRY_URL"

    if id "$DEPLOY_USER" >/dev/null 2>&1; then
        run_privileged chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$base_dir"
    fi

    # Red Docker aislada por ambiente
    if run_docker network inspect "$net_name" >/dev/null 2>&1; then
        log_ok "[${env_name}] Red Docker aislada '${net_name}' ya existe (idempotente)."
    else
        run_docker network create --driver bridge "$net_name" >/dev/null
        log_ok "[${env_name}] Red Docker aislada '${net_name}' creada."
    fi

    # Validar el manifiesto con las variables externalizadas
    run_docker compose --env-file "${base_dir}/.env" -f "${base_dir}/compose/docker-compose.dev.yml" config -q
    log_ok "[${env_name}] Manifiesto validado con secretos externalizados (${base_dir}/.env)."

    # US-08: la pila completa debe renderizar con el mismo .env (IMAGE_TAG SemVer, secretos, healthchecks).
    run_docker compose --env-file "${base_dir}/.env" -f "${base_dir}/compose/stack/${stack_file}" config -q
    log_ok "[${env_name}] Pila completa ${stack_file} validada con ${base_dir}/.env."

    if [[ "$START_MIDDLEWARE" == "true" ]]; then
        log_info "[${env_name}] Levantando contenedores de middleware en ${base_dir}..."
        run_docker compose --env-file "${base_dir}/.env" -f "${base_dir}/compose/docker-compose.dev.yml" up -d --remove-orphans
        log_ok "[${env_name}] Middleware levantado."
    fi
}

print_env_summary() {
    local env_name="$1"
    local base_dir="${STATE_ROOT}${DEPLOY_BASE_DIR}/${env_name}"
    cat <<EOF

================================================================================
 Entorno Aislado CircleGuard — Resumen de Aprovisionamiento (US-05)
================================================================================
 Ambiente configurado : ${env_name} (DRY_RUN=${DRY_RUN})
 Directorio aislado   : ${base_dir}
 Archivo de secretos  : ${base_dir}/.env (permisos 0600, fuera de Git)
 Plantilla de ejemplo : ${base_dir}/config/.env.example
 Red Docker aislada   : circleguard_${env_name}_net
 Registro configurado : ${REGISTRY_URL}
================================================================================
EOF
}

bootstrap_single_env() {
    local env_name="$1"
    if [[ "$PROVISION_AWS" == "true" ]]; then
        provision_single_aws_env "$env_name"
        return 0
    fi
    configure_host_kernel_and_swap "$env_name"
    install_docker_and_packages "$env_name"
    configure_registry_and_login "$env_name"
    prepare_isolated_directories_and_secrets "$env_name"
    print_env_summary "$env_name"
}

main() {
    parse_args "$@"
    if [[ "$TARGET_ENV" == "all" ]]; then
        for e in dev stage prod; do
            bootstrap_single_env "$e"
        done
    else
        bootstrap_single_env "$TARGET_ENV"
    fi
}

main "$@"
