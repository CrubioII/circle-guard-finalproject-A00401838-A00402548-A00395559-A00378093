# Aprovisionamiento Idempotente de Entornos Aislados (`dev`, `stage`, `prod`) y Externalización de Secretos (US-05)

## Trazabilidad con Jira
- Historia de usuario: `US-05` (`SCRUM-17`, 5 SP), Script Bash idempotente para aprovisionar los entornos aislados (`dev`, `stage`, `prod`) y externalizar secretos.
- Épica asociada: `EPIC-02` (`SCRUM-9`, Entregable `E1.2`).
- Subtareas:
  - `SCRUM-43` (2 SP): Desarrollar `infra/bootstrap/bootstrap-env.sh` soportando los parámetros `dev`, `stage` y `prod` de forma idempotente.
  - `SCRUM-44` (1 SP): Parametrizar variables de entorno y remover secretos en texto plano de las configuraciones de despliegue, creando `.env.example`.
  - `SCRUM-45` (2 SP): Ejecutar aprovisionamiento de los 3 ambientes en la nube y verificar conectividad SSH/despliegue desde Jenkins.

---

## 1. Externalización de Secretos (`CA2` y `SCRUM-44`)

Se eliminaron todas las contraseñas y credenciales en texto plano que venían quemadas en [`docker-compose.dev.yml`](../../docker-compose.dev.yml) (`POSTGRES_PASSWORD: password`, `NEO4J_AUTH: neo4j/password`, `LDAP_ADMIN_PASSWORD: "admin"`):

1. Variables obligatorias en [`docker-compose.dev.yml`](../../docker-compose.dev.yml):
   - `POSTGRES_USER: "${POSTGRES_USER:?...}"` y `POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:?...}"`
   - `NEO4J_AUTH: "${NEO4J_USER:?...}/${NEO4J_PASSWORD:?...}"`
   - `REDIS_PASSWORD` exigida mediante `redis-server --requirepass "${REDIS_PASSWORD:?...}"`
   - `LDAP_ADMIN_PASSWORD: "${LDAP_ADMIN_PASSWORD:?...}"`
2. Plantillas documentadas en el repositorio (sin secretos reales):
   - [`.env.example`](../../.env.example): plantilla general para desarrollo local y referencia de variables de microservicios y middleware.
   - [`infra/bootstrap/env/.env.dev.example`](../../infra/bootstrap/env/.env.dev.example), [`.env.stage.example`](../../infra/bootstrap/env/.env.stage.example) y [`.env.prod.example`](../../infra/bootstrap/env/.env.prod.example): plantillas específicas por ambiente.
3. Inyección desde el almacén de credenciales de Jenkins:
   - El script [`infra/bootstrap/inject-jenkins-secrets.sh`](../../infra/bootstrap/inject-jenkins-secrets.sh) recibe las variables inyectadas por `withCredentials(...)` de Jenkins y escribe `/opt/circleguard/<env>/.env` con permisos `0600` (`umask 077`). Si se ejecuta durante el aprovisionamiento inicial sin variables externas, genera secretos criptográficos únicos de 16 a 32 bytes hexadecimales con `openssl rand -hex` y los preserva en ejecuciones posteriores sin sobrescribirlos.

---

## 2. Arquitectura de los Tres Ambientes Aislados en AWS EC2 (`CA1`, `CA3` y `SCRUM-45`)

Todos los recursos se aprovisionaron en la Región seleccionada del proyecto (`us-east-2`) mediante [`infra/bootstrap/bootstrap-env.sh`](../../infra/bootstrap/bootstrap-env.sh):

| Ambiente | Instancia EC2 | IP Pública / Privada | Security Group Aislado | Red Docker Aislada | Directorio y Secretos (`0600`) | Base de Datos PostgreSQL |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `dev` | `i-0afac282e0fa495ce` (`m7i-flex.large`, 8 GB RAM) | `52.15.213.209` / `172.31.17.179` | `sg-0b1f66b12e154410d` (`circleguard-dev-sg`) | `circleguard_dev_net` (`bridge`) | `/opt/circleguard/dev/.env` | `circleguard_dev` |
| `stage` | `i-0856938aef6905ddc` (`m7i-flex.large`, 8 GB RAM) | `3.17.163.44` / `172.31.19.153` | `sg-01a67ffaa84eb8d74` (`circleguard-stage-sg`) | `circleguard_stage_net` (`bridge`) | `/opt/circleguard/stage/.env` | `circleguard_stage` |
| `prod` | `i-087a647cdd67fb57a` (`m7i-flex.large`, 8 GB RAM) | `3.19.74.9` / `172.31.21.79` | `sg-02704674d547db612` (`circleguard-prod-sg`) | `circleguard_prod_net` (`bridge`) | `/opt/circleguard/prod/.env` | `circleguard_prod` |

Cada entorno cuenta además con `/etc/docker/daemon.json` configurado hacia el registro privado de imágenes en Nexus (`52.14.6.11:5000`) y soporte para `docker login` no interactivo (`--password-stdin`).

---

## 3. Garantías de Idempotencia en `infra/bootstrap/bootstrap-env.sh` (`CA1` y `SCRUM-43`)

1. Banderas de seguridad: `set -euo pipefail` y validación estricta del parámetro `<dev|stage|prod|all>`.
2. Red y Security Groups: verifica en AWS EC2 si `circleguard-<env>-sg` y sus reglas (`22`, `8080`, `8180`, `8087`) ya existen antes de autorizarlas, y reutiliza las instancias etiquetadas sin duplicarlas.
3. Sistema operativo y Docker: configura `/etc/sysctl.d/99-circleguard-<env>.conf` (`vm.max_map_count = 262144`), `/swapfile` (`2048 MB`), Docker Engine, Docker Compose v2 y `/etc/docker/daemon.json` comparando el contenido antes de escribir o reiniciar el servicio.
4. Aislamiento de directorios, red y secretos: crea `/opt/circleguard/<env>/{compose,config,logs,backups}` con permisos `0750`, reconcilia la red `circleguard_<env>_net`, preserva los secretos existentes en `/opt/circleguard/<env>/.env` (`0600`) y valida la sintaxis del manifiesto con `docker compose --env-file /opt/circleguard/<env>/.env -f /opt/circleguard/<env>/compose/docker-compose.dev.yml config -q`.

---

## 4. Comandos de Ejecución y Verificación (`SCRUM-45`)

### Aprovisionamiento en AWS EC2 de los 3 ambientes
```bash
bash infra/bootstrap/bootstrap-env.sh all --provision-aws --aws-profile personal --aws-region us-east-2
```

### Ejecución local por ambiente en un servidor destino
```bash
sudo bash infra/bootstrap/bootstrap-env.sh dev
sudo bash infra/bootstrap/bootstrap-env.sh stage
sudo bash infra/bootstrap/bootstrap-env.sh prod
```

### Evidencia de conectividad SSH y aislamiento verificada desde el servidor Jenkins (`52.14.6.11`)
```text
=== [Jenkins CI (52.14.6.11) -> 172.31.17.179 (dev)] ===
ip-172-31-17-179.us-east-2.compute.internal
Mem: 7.6Gi total, 7.1Gi available
-rw-------. 1 ec2-user ec2-user 1235 Nov  8 21:57 /opt/circleguard/dev/.env
Network=circleguard_dev_net Driver=bridge

=== [Jenkins CI (52.14.6.11) -> 172.31.19.153 (stage)] ===
ip-172-31-19-153.us-east-2.compute.internal
Mem: 7.6Gi total, 7.1Gi available
-rw-------. 1 ec2-user ec2-user 1251 Nov  8 21:57 /opt/circleguard/stage/.env
Network=circleguard_stage_net Driver=bridge

=== [Jenkins CI (52.14.6.11) -> 172.31.21.79 (prod)] ===
ip-172-31-21-79.us-east-2.compute.internal
Mem: 7.6Gi total, 7.1Gi available
-rw-------. 1 ec2-user ec2-user 1243 Nov  8 21:58 /opt/circleguard/prod/.env
Network=circleguard_prod_net Driver=bridge
```

### Suite automatizada de idempotencia y externalización de secretos
```bash
./infra/bootstrap/test-bootstrap-env-idempotency.sh
```
