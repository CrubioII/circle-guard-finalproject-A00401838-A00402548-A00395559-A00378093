#!/usr/bin/env bash
# =============================================================================
# Script Bash idempotente para aprovisionar el plano de control CI/CD (US-04 / SCRUM-16)
# Herramientas aprovisionadas:
#   1. Jenkins Controller/Agent (Java 21, Gradle 8.5, Docker CLI/socket, Node.js 20, Playwright deps)
#   2. SonarQube 10.6 Community + PostgreSQL 16 (con vm.max_map_count=262144 y ulimits)
#   3. Sonatype Nexus Repository 3 (Artefactos Maven/raw en :8081 y Docker Registry en :5000)
#
# Modos de operación:
#   A. En la instancia EC2 (local al servidor):
#      sudo bash infra/bootstrap/bootstrap-ci.sh --public-host <IP_PUBLICA>
#   B. Desde estación de trabajo hacia AWS EC2 (crea/reconcilia SG + EC2 en la Región seleccionada
#      y ejecuta este mismo script dentro de la instancia):
#      bash infra/bootstrap/bootstrap-ci.sh --provision-aws --aws-profile personal --aws-region us-east-2
#
# Garantías de idempotencia (CA1, CA2, CA3):
#   - Banderas estrictas: set -euo pipefail
#   - No duplica Security Groups ni instancias EC2 si ya existen con el tag Name=circleguard-ci-server
#   - No duplica entradas en /etc/sysctl.d/, /etc/security/limits.d/ ni /etc/fstab
#   - No reinstala Docker/Docker Compose si ya están presentes y activos
#   - No sobrescribe infra/bootstrap/.env.ci si ya fue creado previamente
#   - Reconcilia contenedores y volúmenes persistentes con docker compose up -d
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Parámetros configurables por variables de entorno o banderas CLI
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-all}"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/docker-compose.ci.yml}"
ENV_TEMPLATE="${ENV_TEMPLATE:-${SCRIPT_DIR}/.env.ci.example}"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env.ci}"
CI_PUBLIC_HOST="${CI_PUBLIC_HOST:-localhost}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
REQUIRED_MAX_MAP_COUNT="${REQUIRED_MAX_MAP_COUNT:-262144}"
REQUIRED_FILE_MAX="${REQUIRED_FILE_MAX:-131072}"
HEALTH_WAIT_TIMEOUT="${HEALTH_WAIT_TIMEOUT:-300}"
WAIT_FOR_HEALTH="${WAIT_FOR_HEALTH:-true}"
DRY_RUN="${DRY_RUN:-false}"
STATE_ROOT="${STATE_ROOT:-}"

# Parámetros para aprovisionamiento remoto idempotente en AWS EC2
PROVISION_AWS="${PROVISION_AWS:-false}"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-personal}"
AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-2}"
EC2_INSTANCE_NAME="${EC2_INSTANCE_NAME:-circleguard-ci-server}"
EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-m7i-flex.large}"
EC2_AMI_ID="${EC2_AMI_ID:-ami-02dae70ab25064279}"
EC2_KEY_NAME="${EC2_KEY_NAME:-proyectoIngeClave}"
EC2_SSH_KEY_PATH="${EC2_SSH_KEY_PATH:-${REPO_ROOT}/proyectoIngeClave.pem}"
EC2_SSH_USER="${EC2_SSH_USER:-ec2-user}"
EC2_SG_NAME="${EC2_SG_NAME:-circleguard-ci-control-plane-sg}"
EC2_VOLUME_SIZE_GB="${EC2_VOLUME_SIZE_GB:-30}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/opt/circleguard-ci}"

log_info()  { printf '[bootstrap-ci][INFO]  %s\n' "$*"; }
log_ok()    { printf '[bootstrap-ci][OK]    %s\n' "$*"; }
log_warn()  { printf '[bootstrap-ci][WARN]  %s\n' "$*" >&2; }
log_error() { printf '[bootstrap-ci][ERROR] %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Uso: infra/bootstrap/bootstrap-ci.sh [opciones]

Opciones de servidor CI/CD:
  --mode <all|jenkins|sonarqube|nexus>  Servicios a levantar (por defecto: all)
  --compose-file <ruta>                 Ruta al manifiesto Docker Compose (por defecto: docker-compose.ci.yml)
  --env-file <ruta>                     Ruta al archivo .env.ci (por defecto: infra/bootstrap/.env.ci)
  --public-host <host/IP>               IP pública o DNS de la instancia EC2 (por defecto: localhost)
  --swap-mb <MB>                        Tamaño de swap en MB si la instancia no tiene swap (por defecto: 2048)
  --wait-timeout <segundos>             Tiempo máximo de espera para healthchecks (por defecto: 300)
  --no-wait                             No esperar el bucle de healthchecks tras levantar contenedores
  --state-dir <directorio>              Prefijo de estado para validación aislada de idempotencia
  --dry-run                             Valida prerrequisitos e idempotencia sin mutar el kernel ni demonios del host

Opciones de aprovisionamiento en nube (AWS EC2 en la Región seleccionada):
  --provision-aws                       Aprovisiona/reconcilia SG + instancia EC2 en AWS y ejecuta bootstrap remoto
  --aws-profile <perfil>                Perfil de AWS CLI (por defecto: personal)
  --aws-region <región>                 Región seleccionada del proyecto AWS (por defecto: us-east-2)
  --instance-type <tipo>                Tipo de instancia EC2 (por defecto: m7i-flex.large)
  --ssh-key-path <ruta>                 Ruta a la llave privada SSH (por defecto: ./proyectoIngeClave.pem)
  -h, --help                            Muestra esta ayuda
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                BOOTSTRAP_MODE="${2:?Falta valor para --mode}"
                shift 2
                ;;
            --compose-file)
                COMPOSE_FILE="${2:?Falta valor para --compose-file}"
                shift 2
                ;;
            --env-file)
                ENV_FILE="${2:?Falta valor para --env-file}"
                shift 2
                ;;
            --public-host)
                CI_PUBLIC_HOST="${2:?Falta valor para --public-host}"
                shift 2
                ;;
            --swap-mb)
                SWAP_SIZE_MB="${2:?Falta valor para --swap-mb}"
                shift 2
                ;;
            --wait-timeout)
                HEALTH_WAIT_TIMEOUT="${2:?Falta valor para --wait-timeout}"
                shift 2
                ;;
            --no-wait)
                WAIT_FOR_HEALTH="false"
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
                log_error "Opción no reconocida: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$BOOTSTRAP_MODE" in
        all|jenkins|sonarqube|nexus) ;;
        *)
            log_error "Modo inválido '${BOOTSTRAP_MODE}'. Valores permitidos: all, jenkins, sonarqube, nexus."
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
# Aprovisionamiento idempotente de Security Group e instancia EC2 en AWS
# -----------------------------------------------------------------------------
provision_aws_ec2_and_bootstrap() {
    log_info "Iniciando aprovisionamiento idempotente en AWS EC2 (perfil=${AWS_PROFILE_NAME}, región=${AWS_REGION_NAME})..."

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
    log_ok "VPC detectada en ${AWS_REGION_NAME}: ${vpc_id}"

    # 1. Reconciliar Security Group de forma idempotente
    local sg_id
    sg_id="$(aws ec2 describe-security-groups \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --filters "Name=group-name,Values=${EC2_SG_NAME}" "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>/dev/null || echo "None")"

    if [[ -z "$sg_id" ]] || [[ "$sg_id" == "None" ]]; then
        log_info "Creando Security Group '${EC2_SG_NAME}' en ${vpc_id}..."
        sg_id="$(aws ec2 create-security-group \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --group-name "$EC2_SG_NAME" \
            --description "Security Group para el plano de control CI/CD de CircleGuard (US-04)" \
            --vpc-id "$vpc_id" \
            --query "GroupId" \
            --output text)"
        log_ok "Security Group creado: ${sg_id}"
    else
        log_ok "Security Group '${EC2_SG_NAME}' ya existe (${sg_id}); reutilizando de forma idempotente."
    fi

    # Autorizar puertos requeridos (22 SSH, 8080 Jenkins, 9000 SonarQube, 8081 Nexus UI, 5000 Docker Registry)
    for port in 22 8080 9000 8081 5000; do
        local exists_rule
        exists_rule="$(aws ec2 describe-security-groups \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --group-ids "$sg_id" \
            --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\` && ToPort==\`${port}\`].FromPort" \
            --output text 2>/dev/null || true)"
        if [[ -n "$exists_rule" ]] && [[ "$exists_rule" != "None" ]]; then
            log_ok "Regla TCP/${port} ya autorizada en ${sg_id}."
        else
            aws ec2 authorize-security-group-ingress \
                --profile "$AWS_PROFILE_NAME" \
                --region "$AWS_REGION_NAME" \
                --group-id "$sg_id" \
                --protocol tcp \
                --port "$port" \
                --cidr "0.0.0.0/0" >/dev/null
            log_ok "Regla TCP/${port} agregada a ${sg_id}."
        fi
    done

    # 2. Verificar si la instancia EC2 ya existe (pending o running)
    local instance_id
    instance_id="$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --filters "Name=tag:Name,Values=${EC2_INSTANCE_NAME}" "Name=instance-state-name,Values=pending,running" \
        --query "Reservations[].Instances[0].InstanceId | [0]" \
        --output text 2>/dev/null || echo "None")"

    if [[ -z "$instance_id" ]] || [[ "$instance_id" == "None" ]]; then
        log_info "Lanzando instancia EC2 '${EC2_INSTANCE_NAME}' (${EC2_INSTANCE_TYPE}, ${EC2_VOLUME_SIZE_GB} GB gp3) en ${AWS_REGION_NAME}..."
        instance_id="$(aws ec2 run-instances \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --image-id "$EC2_AMI_ID" \
            --instance-type "$EC2_INSTANCE_TYPE" \
            --key-name "$EC2_KEY_NAME" \
            --security-group-ids "$sg_id" \
            --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${EC2_VOLUME_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true}" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${EC2_INSTANCE_NAME}},{Key=Project,Value=CircleGuard},{Key=UserStory,Value=US-04}]" \
            --query "Instances[0].InstanceId" \
            --output text)"
        log_ok "Instancia EC2 creada: ${instance_id}. Esperando estado 'running'..."
        aws ec2 wait instance-running \
            --profile "$AWS_PROFILE_NAME" \
            --region "$AWS_REGION_NAME" \
            --instance-ids "$instance_id"
    else
        log_ok "Instancia EC2 '${EC2_INSTANCE_NAME}' ya existe (${instance_id}); reutilizando sin duplicar recursos."
    fi

    local public_ip
    public_ip="$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE_NAME" \
        --region "$AWS_REGION_NAME" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)"
    log_ok "Instancia ${instance_id} activa en IP pública: ${public_ip}"

    # 3. Esperar disponibilidad SSH
    log_info "Esperando conectividad SSH hacia ${EC2_SSH_USER}@${public_ip}..."
    local ssh_ready="false"
    for _ in $(seq 1 30); do
        if ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${EC2_SSH_USER}@${public_ip}" "echo ok" >/dev/null 2>&1; then
            ssh_ready="true"
            break
        fi
        sleep 5
    done
    if [[ "$ssh_ready" != "true" ]]; then
        log_error "No se logró establecer conexión SSH con ${public_ip}."
        exit 1
    fi
    log_ok "Conectividad SSH verificada con ${public_ip}."

    # 4. Sincronizar artefactos de aprovisionamiento hacia /opt/circleguard-ci
    log_info "Sincronizando manifiestos y scripts hacia ${public_ip}:${REMOTE_APP_DIR}..."
    ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no "${EC2_SSH_USER}@${public_ip}" \
        "sudo mkdir -p '${REMOTE_APP_DIR}' && sudo chown -R ${EC2_SSH_USER}:${EC2_SSH_USER} '${REMOTE_APP_DIR}'"

    COPYFILE_DISABLE=1 tar --no-xattrs -C "$REPO_ROOT" -czf - \
        docker-compose.ci.yml \
        infra/bootstrap \
        jenkins/ci \
        2>/dev/null \
        | ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no "${EC2_SSH_USER}@${public_ip}" \
            "tar -C '${REMOTE_APP_DIR}' -xzf -"

    # 5. Ejecutar bootstrap-ci.sh dentro de la instancia EC2
    log_info "Ejecutando bootstrap-ci.sh en la instancia remota ${public_ip} (modo=${BOOTSTRAP_MODE})..."
    ssh -i "$EC2_SSH_KEY_PATH" -o StrictHostKeyChecking=no "${EC2_SSH_USER}@${public_ip}" \
        "sudo bash '${REMOTE_APP_DIR}/infra/bootstrap/bootstrap-ci.sh' --mode '${BOOTSTRAP_MODE}' --public-host '${public_ip}' --wait-timeout '${HEALTH_WAIT_TIMEOUT}'"
}

validate_repository_files() {
    log_info "Verificando artefactos de aprovisionamiento CI/CD..."
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "No se encontró el manifiesto Docker Compose: ${COMPOSE_FILE}"
        exit 1
    fi
    if [[ ! -f "$ENV_TEMPLATE" ]]; then
        log_error "No se encontró la plantilla de entorno: ${ENV_TEMPLATE}"
        exit 1
    fi
    if [[ ! -f "${SCRIPT_DIR}/jenkins/Dockerfile" ]]; then
        log_error "No se encontró el Dockerfile personalizado de Jenkins: ${SCRIPT_DIR}/jenkins/Dockerfile"
        exit 1
    fi
    log_ok "Manifiestos verificados (${COMPOSE_FILE}, ${SCRIPT_DIR}/jenkins/Dockerfile)."
}

# -----------------------------------------------------------------------------
# CA2: Configuración idempotente de parámetros de kernel (vm.max_map_count=262144)
# y límites de descriptores para SonarQube / Elasticsearch
# -----------------------------------------------------------------------------
configure_kernel_parameters() {
    local sysctl_file="${STATE_ROOT}/etc/sysctl.d/99-circleguard-ci.conf"
    local limits_file="${STATE_ROOT}/etc/security/limits.d/99-circleguard-ci.conf"

    log_info "Verificando parámetros de kernel para SonarQube (vm.max_map_count=${REQUIRED_MAX_MAP_COUNT}, fs.file-max=${REQUIRED_FILE_MAX})..."

    local desired_sysctl
    desired_sysctl="$(cat <<EOF
# Generado de forma idempotente por infra/bootstrap/bootstrap-ci.sh (US-04)
vm.max_map_count = ${REQUIRED_MAX_MAP_COUNT}
fs.file-max = ${REQUIRED_FILE_MAX}
EOF
)"

    local desired_limits
    desired_limits="$(cat <<'EOF'
# Generado de forma idempotente por infra/bootstrap/bootstrap-ci.sh (US-04)
* soft nofile 65536
* hard nofile 65536
* soft nproc 4096
* hard nproc 4096
EOF
)"

    if [[ -n "$STATE_ROOT" ]]; then
        mkdir -p "$(dirname "$sysctl_file")" "$(dirname "$limits_file")"
        if [[ -f "$sysctl_file" ]] && [[ "$(cat "$sysctl_file")" == "$desired_sysctl" ]]; then
            log_ok "Archivo sysctl (${sysctl_file}) ya está actualizado (sin cambios)."
        else
            printf '%s\n' "$desired_sysctl" > "$sysctl_file"
            log_ok "Archivo sysctl escrito en ${sysctl_file}."
        fi

        if [[ -f "$limits_file" ]] && [[ "$(cat "$limits_file")" == "$desired_limits" ]]; then
            log_ok "Archivo limits (${limits_file}) ya está actualizado (sin cambios)."
        else
            printf '%s\n' "$desired_limits" > "$limits_file"
            log_ok "Archivo limits escrito en ${limits_file}."
        fi
        return 0
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_warn "Sistema operativo $(uname -s) detectado; omitiendo sysctl de kernel Linux directo."
        return 0
    fi

    local current_map_count=0
    current_map_count="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
    if [[ "$current_map_count" -ge "$REQUIRED_MAX_MAP_COUNT" ]]; then
        log_ok "vm.max_map_count actual (${current_map_count}) ya cumple el mínimo (${REQUIRED_MAX_MAP_COUNT})."
    else
        log_info "Ajustando vm.max_map_count de ${current_map_count} a ${REQUIRED_MAX_MAP_COUNT}..."
        run_privileged sysctl -w "vm.max_map_count=${REQUIRED_MAX_MAP_COUNT}"
    fi

    local current_file_max=0
    current_file_max="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
    if [[ "$current_file_max" -ge "$REQUIRED_FILE_MAX" ]]; then
        log_ok "fs.file-max actual (${current_file_max}) ya cumple el mínimo (${REQUIRED_FILE_MAX})."
    else
        log_info "Ajustando fs.file-max de ${current_file_max} a ${REQUIRED_FILE_MAX}..."
        run_privileged sysctl -w "fs.file-max=${REQUIRED_FILE_MAX}"
    fi

    if [[ -f "$sysctl_file" ]] && [[ "$(cat "$sysctl_file" 2>/dev/null || true)" == "$desired_sysctl" ]]; then
        log_ok "Persistencia sysctl en ${sysctl_file} ya configurada (idempotente)."
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Escribir ${sysctl_file} y recargar sysctl -p ${sysctl_file}"
        else
            printf '%s\n' "$desired_sysctl" | run_privileged tee "$sysctl_file" >/dev/null
            run_privileged sysctl -p "$sysctl_file" >/dev/null
            log_ok "Persistencia sysctl actualizada en ${sysctl_file}."
        fi
    fi

    if [[ -f "$limits_file" ]] && [[ "$(cat "$limits_file" 2>/dev/null || true)" == "$desired_limits" ]]; then
        log_ok "Límites ulimit en ${limits_file} ya configurados (idempotente)."
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Escribir ${limits_file}"
        else
            printf '%s\n' "$desired_limits" | run_privileged tee "$limits_file" >/dev/null
            log_ok "Límites ulimit actualizados en ${limits_file}."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Configuración idempotente de memoria Swap en instancias EC2
# -----------------------------------------------------------------------------
configure_swap_space() {
    if [[ "${SWAP_SIZE_MB}" -le 0 ]]; then
        log_info "Configuración de swap deshabilitada (SWAP_SIZE_MB=${SWAP_SIZE_MB})."
        return 0
    fi

    local fstab_file="${STATE_ROOT}/etc/fstab"
    local swap_file="${STATE_ROOT}/swapfile"

    if [[ -n "$STATE_ROOT" ]]; then
        mkdir -p "$(dirname "$fstab_file")"
        touch "$fstab_file"
        if grep -q '^/swapfile ' "$fstab_file" 2>/dev/null; then
            log_ok "Swap ya registrado en ${fstab_file} (sin duplicar entrada)."
        else
            printf '/swapfile none swap sw 0 0\n' >> "$fstab_file"
            touch "$swap_file"
            log_ok "Swap registrado de forma idempotente en ${fstab_file}."
        fi
        return 0
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        log_info "Omitiendo configuración de /swapfile en entorno no Linux ($(uname -s))."
        return 0
    fi

    if swapon --show 2>/dev/null | grep -q '/'; then
        log_ok "Swap ya se encuentra activo en el sistema (idempotente)."
        return 0
    fi

    log_info "Aprovisionando archivo swap de ${SWAP_SIZE_MB} MB en /swapfile..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Crear /swapfile (${SWAP_SIZE_MB}M), mkswap, swapon y registrar en /etc/fstab"
        return 0
    fi

    if [[ ! -f /swapfile ]]; then
        run_privileged dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}" status=none
        run_privileged chmod 600 /swapfile
        run_privileged mkswap /swapfile >/dev/null
    fi
    run_privileged swapon /swapfile

    if ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
        printf '/swapfile none swap sw 0 0\n' | run_privileged tee -a /etc/fstab >/dev/null
    fi
    log_ok "Swap de ${SWAP_SIZE_MB} MB habilitado y persistido en /etc/fstab."
}

# -----------------------------------------------------------------------------
# CA2: Instalación idempotente de paquetes base, Docker Engine y Docker Compose v2
# -----------------------------------------------------------------------------
install_system_and_docker() {
    log_info "Verificando paquetes base del sistema, Docker Engine y Docker Compose v2..."

    local missing_base=()
    for cmd in curl git jq unzip tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_base+=("$cmd")
        fi
    done

    if [[ ${#missing_base[@]} -eq 0 ]]; then
        log_ok "Utilidades base (curl, git, jq, unzip, tar) ya instaladas."
    else
        log_info "Instalando utilidades faltantes: ${missing_base[*]}..."
        if command -v apt-get >/dev/null 2>&1; then
            run_privileged apt-get update -y
            run_privileged apt-get install -y --no-install-recommends ca-certificates gnupg "${missing_base[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            run_privileged dnf install -y ca-certificates "${missing_base[@]}"
        elif command -v yum >/dev/null 2>&1; then
            run_privileged yum install -y ca-certificates "${missing_base[@]}"
        else
            log_warn "Gestor de paquetes no reconocido para instalar: ${missing_base[*]}"
        fi
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_ok "Docker ($(docker --version 2>/dev/null | head -n 1)) y Docker Compose v2 ya están instalados."
    else
        log_info "Instalando Docker Engine y Docker Compose plugin..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Instalar Docker Engine y docker-compose-plugin según la distribución Linux"
        elif command -v apt-get >/dev/null 2>&1; then
            run_privileged apt-get update -y
            run_privileged apt-get install -y --no-install-recommends ca-certificates curl gnupg
            run_privileged install -m 0755 -d /etc/apt/keyrings
            if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | run_privileged gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                run_privileged chmod a+r /etc/apt/keyrings/docker.gpg
            fi
            # shellcheck disable=SC1091
            source /etc/os-release
            local distro_id="${ID:-ubuntu}"
            local codename="${VERSION_CODENAME:-jammy}"
            printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
                "$(dpkg --print-architecture)" "$distro_id" "$codename" \
                | run_privileged tee /etc/apt/sources.list.d/docker.list >/dev/null
            run_privileged apt-get update -y
            run_privileged apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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
                # Instalar también docker-buildx para soportar 'docker compose up --build' en Amazon Linux 2023
                local buildx_arch="amd64"
                if [[ "$arch" == "aarch64" ]]; then buildx_arch="arm64"; fi
                run_privileged curl -fsSL "https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-${buildx_arch}" \
                    -o /usr/local/lib/docker/cli-plugins/docker-buildx
                run_privileged chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
                run_privileged cp -f /usr/local/lib/docker/cli-plugins/docker-buildx /usr/libexec/docker/cli-plugins/docker-buildx
            fi
        elif command -v yum >/dev/null 2>&1; then
            if ! command -v docker >/dev/null 2>&1; then
                run_privileged yum install -y docker
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
        else
            log_error "No se encontró un gestor de paquetes compatible para instalar Docker."
            exit 1
        fi
    fi

    if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            log_ok "Servicio systemd 'docker' ya se encuentra activo."
        else
            log_info "Habilitando e iniciando el servicio 'docker'..."
            run_privileged systemctl enable --now docker
        fi
    fi

    local target_user="${SUDO_USER:-${USER:-}}"
    if [[ "$(uname -s)" == "Linux" ]] && [[ -n "$target_user" ]] && [[ "$target_user" != "root" ]]; then
        if id -nG "$target_user" 2>/dev/null | tr ' ' '\n' | grep -qx "docker"; then
            log_ok "El usuario '${target_user}' ya pertenece al grupo 'docker'."
        else
            log_info "Agregando al usuario '${target_user}' al grupo 'docker'..."
            run_privileged usermod -aG docker "$target_user"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Generación idempotente de infra/bootstrap/.env.ci sin sobrescribir secretos previos
# -----------------------------------------------------------------------------
prepare_env_file() {
    local target_env="$ENV_FILE"
    if [[ -n "$STATE_ROOT" ]]; then
        target_env="${STATE_ROOT}/.env.ci"
    fi

    mkdir -p "$(dirname "$target_env")"

    local docker_gid="999"
    if command -v getent >/dev/null 2>&1 && getent group docker >/dev/null 2>&1; then
        docker_gid="$(getent group docker | cut -d: -f3)"
    fi

    if [[ -f "$target_env" ]]; then
        log_ok "Archivo de entorno ${target_env} ya existe; se conserva sin sobrescribir (idempotente)."
    else
        cp "$ENV_TEMPLATE" "$target_env"
        chmod 600 "$target_env"
        local tmp_file="${target_env}.tmp"
        sed \
            -e "s|^CI_PUBLIC_HOST=.*|CI_PUBLIC_HOST=${CI_PUBLIC_HOST}|" \
            -e "s|^JENKINS_URL=.*|JENKINS_URL=http://${CI_PUBLIC_HOST}:8080/|" \
            -e "s|^DOCKER_GID=.*|DOCKER_GID=${docker_gid}|" \
            -e "s|^DOCKER_REGISTRY_URL=.*|DOCKER_REGISTRY_URL=${CI_PUBLIC_HOST}:5000|" \
            "$target_env" > "$tmp_file"
        mv "$tmp_file" "$target_env"
        chmod 600 "$target_env"
        log_ok "Archivo de entorno inicializado en ${target_env}."
    fi

    ENV_FILE="$target_env"
}

resolve_target_services() {
    case "$BOOTSTRAP_MODE" in
        all)
            printf 'jenkins sonarqube-db sonarqube nexus\n'
            ;;
        jenkins)
            printf 'jenkins\n'
            ;;
        sonarqube)
            printf 'sonarqube-db sonarqube\n'
            ;;
        nexus)
            printf 'nexus\n'
            ;;
    esac
}

# -----------------------------------------------------------------------------
# CA2 y CA3: Despliegue declarativo e idempotente con Docker Compose y volúmenes
# -----------------------------------------------------------------------------
deploy_ci_services() {
    local services_str
    services_str="$(resolve_target_services)"
    # shellcheck disable=SC2206
    local target_services=($services_str)

    log_info "Validando sintaxis del manifiesto ${COMPOSE_FILE}..."
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        run_docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q
        log_ok "Sintaxis de ${COMPOSE_FILE} validada con docker compose config."
    else
        log_warn "Docker Compose CLI no disponible en este host; omitiendo validación 'docker compose config'."
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} up -d --build --remove-orphans ${target_services[*]}"
        return 0
    fi

    log_info "Reconciliando contenedores y volúmenes persistentes para modo '${BOOTSTRAP_MODE}' (${target_services[*]})..."
    run_docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --build --remove-orphans "${target_services[@]}"
    log_ok "Contenedores del plano de control CI/CD reconciliados."
}

# -----------------------------------------------------------------------------
# CA3: Verificación activa de healthchecks de los contenedores aprovisionados
# -----------------------------------------------------------------------------
wait_for_service_health() {
    local container_name="$1"
    local timeout_secs="$2"

    if [[ "$DRY_RUN" == "true" ]] || [[ "$WAIT_FOR_HEALTH" != "true" ]]; then
        log_info "Omitiendo espera activa de healthcheck para ${container_name} (DRY_RUN=${DRY_RUN}, WAIT_FOR_HEALTH=${WAIT_FOR_HEALTH})."
        return 0
    fi

    log_info "Esperando healthcheck 'healthy' para contenedor '${container_name}' (máx. ${timeout_secs}s)..."
    local elapsed=0
    local interval=5
    while [[ "$elapsed" -lt "$timeout_secs" ]]; do
        local status
        status="$(run_docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || echo "missing")"
        if [[ "$status" == "healthy" ]]; then
            log_ok "Contenedor '${container_name}' reporta estado HEALTHY."
            return 0
        fi
        if [[ "$status" == "exited" ]] || [[ "$status" == "dead" ]]; then
            log_error "Contenedor '${container_name}' terminó inesperadamente con estado '${status}'."
            run_docker logs --tail 40 "$container_name" >&2 || true
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Tiempo de espera agotado (${timeout_secs}s) esperando que '${container_name}' alcance estado HEALTHY."
    return 1
}

verify_all_healthchecks() {
    case "$BOOTSTRAP_MODE" in
        all)
            wait_for_service_health "circleguard-jenkins" "$HEALTH_WAIT_TIMEOUT"
            wait_for_service_health "circleguard-sonarqube-db" "$HEALTH_WAIT_TIMEOUT"
            wait_for_service_health "circleguard-sonarqube" "$HEALTH_WAIT_TIMEOUT"
            wait_for_service_health "circleguard-nexus" "$HEALTH_WAIT_TIMEOUT"
            ;;
        jenkins)
            wait_for_service_health "circleguard-jenkins" "$HEALTH_WAIT_TIMEOUT"
            ;;
        sonarqube)
            wait_for_service_health "circleguard-sonarqube-db" "$HEALTH_WAIT_TIMEOUT"
            wait_for_service_health "circleguard-sonarqube" "$HEALTH_WAIT_TIMEOUT"
            ;;
        nexus)
            wait_for_service_health "circleguard-nexus" "$HEALTH_WAIT_TIMEOUT"
            ;;
    esac
}

print_summary() {
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    local host="${CI_PUBLIC_HOST:-localhost}"
    local j_port="${JENKINS_HTTP_PORT:-8080}"
    local j_agent="${JENKINS_AGENT_PORT:-50000}"
    local s_port="${SONARQUBE_PORT:-9000}"
    local n_port="${NEXUS_HTTP_PORT:-8081}"
    local r_port="${NEXUS_DOCKER_REGISTRY_PORT:-5000}"

    cat <<EOF

================================================================================
 Plano de Control CI/CD CircleGuard — Resumen de Aprovisionamiento (US-04)
================================================================================
 Modo ejecutado       : ${BOOTSTRAP_MODE} (DRY_RUN=${DRY_RUN})
 Archivo Compose      : ${COMPOSE_FILE}
 Archivo de entorno   : ${ENV_FILE}

 Servicios y URLs de acceso:
   - Jenkins UI       : http://${host}:${j_port}/          (Health: /login)
   - Jenkins JNLP     : tcp://${host}:${j_agent}
   - SonarQube UI     : http://${host}:${s_port}/          (Health: /api/system/status)
   - Nexus UI / Maven : http://${host}:${n_port}/          (Health: /service/rest/v1/status)
   - Docker Registry  : http://${host}:${r_port}/v2/       (Conector Docker en Nexus)

 Volúmenes persistentes configurados:
   - circleguard_jenkins_home
   - circleguard_sonarqube_db_data
   - circleguard_sonarqube_data
   - circleguard_sonarqube_extensions
   - circleguard_sonarqube_logs
   - circleguard_nexus_data
================================================================================
EOF
}

main() {
    parse_args "$@"
    validate_repository_files
    if [[ "$PROVISION_AWS" == "true" ]]; then
        provision_aws_ec2_and_bootstrap
        return 0
    fi
    configure_kernel_parameters
    configure_swap_space
    install_system_and_docker
    prepare_env_file
    deploy_ci_services
    verify_all_healthchecks
    print_summary
}

main "$@"
