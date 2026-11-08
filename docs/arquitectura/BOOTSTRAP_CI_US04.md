# Aprovisionamiento Idempotente del Plano de Control CI/CD (US-04)

## Trazabilidad con Jira
- Historia de usuario: `US-04` (`SCRUM-16`, 5 SP), Script Bash idempotente para aprovisionar servidores de herramientas CI/CD (Jenkins, SonarQube y Nexus).
- Épica asociada: `EPIC-02` (`SCRUM-9`, Entregable `E1.2`).
- Subtareas:
  - `SCRUM-40` (2 SP): Crear manifiesto `docker-compose.ci.yml` y `Dockerfile` personalizado de agente/servidor Jenkins (Java 21 + Docker CLI + Playwright deps), SonarQube y Nexus.
  - `SCRUM-41` (2 SP): Desarrollar script idempotente `infra/bootstrap/bootstrap-ci.sh` para aprovisionar la instancia en la nube desde cero.
  - `SCRUM-42` (1 SP): Verificar ejecución repetida del script (prueba de idempotencia) y documentar URLs y puertos de acceso.

---

## 1. Arquitectura del Plano de Control CI/CD

El plano de control CI/CD de CircleGuard se compone de tres servicios principales más la base de datos relacional dedicada a SonarQube, orquestados mediante [`docker-compose.ci.yml`](../../docker-compose.ci.yml) y aprovisionados desde cero con [`infra/bootstrap/bootstrap-ci.sh`](../../infra/bootstrap/bootstrap-ci.sh):

1. Jenkins (`circleguard-jenkins`): construido a partir de [`infra/bootstrap/jenkins/Dockerfile`](../../infra/bootstrap/jenkins/Dockerfile) sobre `jenkins/jenkins:2.580.2-jdk21`. Incluye OpenJDK 21 (`21.0.13`), Gradle 8.5, Node.js 20 LTS (`v20.20.2`), Docker CLI con Docker Compose v2, las librerías del sistema requeridas por Playwright (Chromium headless) y los plugins preinstalados desde [`infra/bootstrap/jenkins/plugins.txt`](../../infra/bootstrap/jenkins/plugins.txt). Monta `/var/run/docker.sock` y la configuración JCasC de [`jenkins/ci/jenkins.yaml`](../../jenkins/ci/jenkins.yaml).
2. SonarQube (`circleguard-sonarqube`) y PostgreSQL (`circleguard-sonarqube-db`): análisis estático de código y evaluación del Quality Gate con imágenes fijadas en `sonarqube:10.6.0-community` y `postgres:16.4-alpine`.
3. Sonatype Nexus Repository OSS 3 (`circleguard-nexus`): almacén de artefactos en el puerto `8081` y registro privado de contenedores Docker en el puerto `5000` con la imagen `sonatype/nexus3:3.70.1`.

---

## 2. Instancia Aprovisionada en AWS EC2, URLs, Puertos y Healthchecks

### Recursos de nube en la Región seleccionada (`us-east-2`)
- Instancia del plano de control CI/CD (`circleguard-ci-server`): `i-0f933271f06cf571d` (`m7i-flex.large`, 8 GB RAM, 30 GB EBS `gp3`, Amazon Linux 2023).
- IP pública del plano de control CI/CD: `52.14.6.11`
- Security Group (`circleguard-ci-control-plane-sg`): `sg-0b600afa26557c730` (puertos `22`, `8080`, `9000`, `8081`, `5000`).
- Servidor Jenkins de webhooks activos (`proyectoIngesoft`): `i-049ab346f627b61a6` (`http://3.145.182.10:8080/`).

### Tabla de Servicios, Puertos, URLs y Healthchecks (`52.14.6.11`)

| Servicio | Contenedor | Imagen (versión fija) | Puertos expuestos | URL pública de acceso | Endpoint de Healthcheck | Volumen persistente |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Jenkins Controller y Agent | `circleguard-jenkins` | `circleguard/jenkins-ci:2.580.2-jdk21` | `8080/tcp` (HTTP), `50000/tcp` (JNLP) | `http://52.14.6.11:8080/` | `GET http://52.14.6.11:8080/login` (`HTTP 200 OK`) | `circleguard_jenkins_home` |
| SonarQube Community | `circleguard-sonarqube` | `sonarqube:10.6.0-community` | `9000/tcp` | `http://52.14.6.11:9000/` | `GET http://52.14.6.11:9000/api/system/status` (`{"status":"UP"}`) | `circleguard_sonarqube_data`, `circleguard_sonarqube_extensions`, `circleguard_sonarqube_logs` |
| Base de datos SonarQube | `circleguard-sonarqube-db` | `postgres:16.4-alpine` | Interno (`5432/tcp` en `ci-network`) | `jdbc:postgresql://sonarqube-db:5432/sonarqube` | `pg_isready -U sonar -d sonarqube` | `circleguard_sonarqube_db_data` |
| Nexus Repository 3 | `circleguard-nexus` | `sonatype/nexus3:3.70.1` | `8081/tcp` (UI y Maven), `5000/tcp` (Docker Registry) | `http://52.14.6.11:8081/` y `http://52.14.6.11:5000/v2/` | `GET http://52.14.6.11:8081/service/rest/v1/status` (`HTTP 200 OK`) | `circleguard_nexus_data` |

---

## 3. Garantías de Idempotencia en `infra/bootstrap/bootstrap-ci.sh`

El script [`infra/bootstrap/bootstrap-ci.sh`](../../infra/bootstrap/bootstrap-ci.sh) aplica `set -euo pipefail` y comprueba el estado previo antes de cada acción:

1. Recursos en AWS EC2 (`--provision-aws`): verifica si el Security Group `circleguard-ci-control-plane-sg` y la instancia con tag `Name=circleguard-ci-server` ya existen en `us-east-2` antes de crearlos, reutilizándolos en corridas posteriores sin duplicar instancias ni fallar al autorizar puertos.
2. Parámetros de kernel (`vm.max_map_count=262144` y `fs.file-max=131072`): consulta el valor activo con `sysctl -n` y compara el contenido exacto de `/etc/sysctl.d/99-circleguard-ci.conf` y `/etc/security/limits.d/99-circleguard-ci.conf`. Solo escribe y recarga `sysctl -p` si el archivo no existe o difiere.
3. Memoria Swap (`/swapfile`): verifica con `swapon --show` si ya hay swap activa y comprueba `grep -q '^/swapfile ' /etc/fstab` antes de registrar la entrada, evitando duplicados en `/etc/fstab`.
4. Paquetes del sistema, Docker y Docker Compose v2: detecta `apt-get`, `dnf` o `yum`, instala únicamente los binarios faltantes (`curl`, `git`, `jq`, `unzip`, `tar`, `docker`, `docker compose`, `docker buildx`), activa `docker.service` si está detenido y añade el usuario operativo al grupo `docker` solo si aún no pertenece a él.
5. Archivo de variables de entorno (`infra/bootstrap/.env.ci`): si `infra/bootstrap/.env.ci` no existe, lo genera a partir de [`infra/bootstrap/.env.ci.example`](../../infra/bootstrap/.env.ci.example) ajustando `CI_PUBLIC_HOST`, `JENKINS_URL` y `DOCKER_GID`. Si ya existe, conserva intactos los valores y contraseñas configurados previamente.
6. Reconciliación declarativa de contenedores: ejecuta `docker compose -f docker-compose.ci.yml --env-file infra/bootstrap/.env.ci up -d --build --remove-orphans`, recreando únicamente contenedores cuya imagen o configuración haya cambiado y preservando los 6 volúmenes nombrados.

---

## 4. Comandos de Ejecución y Evidencia de Idempotencia (`SCRUM-42`)

### Aprovisionamiento desde cero o reconciliación hacia AWS EC2
```bash
bash infra/bootstrap/bootstrap-ci.sh --provision-aws --aws-profile personal --aws-region us-east-2
```

### Ejecución directa dentro de la instancia EC2
```bash
sudo bash infra/bootstrap/bootstrap-ci.sh --public-host 52.14.6.11
```

### Evidencia de segunda ejecución consecutiva (prueba de idempotencia en AWS EC2)
```text
[bootstrap-ci][OK]    Security Group 'circleguard-ci-control-plane-sg' ya existe (sg-0b600afa26557c730); reutilizando de forma idempotente.
[bootstrap-ci][OK]    Instancia EC2 'circleguard-ci-server' ya existe (i-0f933271f06cf571d); reutilizando sin duplicar recursos.
[bootstrap-ci][OK]    vm.max_map_count actual (262144) ya cumple el mínimo (262144).
[bootstrap-ci][OK]    Persistencia sysctl en /etc/sysctl.d/99-circleguard-ci.conf ya configurada (idempotente).
[bootstrap-ci][OK]    Límites ulimit en /etc/security/limits.d/99-circleguard-ci.conf ya configurados (idempotente).
[bootstrap-ci][OK]    Swap ya se encuentra activo en el sistema (idempotente).
[bootstrap-ci][OK]    Docker (Docker version 25.0.14, build 0bab007) y Docker Compose v2 ya están instalados.
[bootstrap-ci][OK]    Archivo de entorno /opt/circleguard-ci/infra/bootstrap/.env.ci ya existe; se conserva sin sobrescribir (idempotente).
[bootstrap-ci][OK]    Contenedor 'circleguard-jenkins' reporta estado HEALTHY.
[bootstrap-ci][OK]    Contenedor 'circleguard-sonarqube-db' reporta estado HEALTHY.
[bootstrap-ci][OK]    Contenedor 'circleguard-sonarqube' reporta estado HEALTHY.
[bootstrap-ci][OK]    Contenedor 'circleguard-nexus' reporta estado HEALTHY.
```

### Suite automatizada local
```bash
./infra/bootstrap/test-bootstrap-ci-idempotency.sh
```
