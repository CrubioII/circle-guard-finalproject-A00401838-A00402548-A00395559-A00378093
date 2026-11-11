# Seguridad de Jenkins y aprobadores de prod (`US-31`)

> **Proyecto:** CircleGuard — Ingeniería de Software V (Universidad Icesi)
> **Entregables:** `E1.2` (plano de control) y `E1.5` (aprobación manual del release a prod).

## 1. Por qué

Hasta esta historia, Jenkins corría sin autenticación (`useSecurity: false`), y eso tenía dos consecuencias:

- **Cualquiera que llegara al puerto 8080 administraba Jenkins.** El contenedor monta `/var/run/docker.sock`, así que administrar Jenkins equivale a ser root en el servidor de CI, donde también viven Nexus y SonarQube.
- **La compuerta de prod de US-31 no podía usarse.** Sin cuentas no hay IDs que poner en `CG_PROD_APPROVERS`. Además, las variables globales escritas a mano se perdían en cada arranque, porque JCasC reemplaza `globalNodeProperties`.

Ahora toda la configuración de seguridad está versionada en JCasC, y las contraseñas quedan fuera del repositorio.

## 2. Cuentas y permisos

| Cuenta | Quién | Permisos |
|---|---|---|
| `admin` | Emergencia y administración (credenciales, plugins, recargar JCasC) | `Overall/Administer` |
| `jrubio` | Juan Camilo Rubio Arboleda | Lectura + `Job/Build`, `Job/Cancel`, `Job/Workspace`, `Run/Update` |
| `ecuellar` | Esteban Cuéllar | Igual que `jrubio` |
| `scastillo` | Santiago Castillo | Igual que `jrubio` |
| `jpordonez` | Juan Pablo Ordóñez | Igual que `jrubio` |
| `docente` | Evaluación | Solo lectura: `Overall/Read`, `Job/Read`, `View/Read` |
| Anónimo | — | Ninguno. Solo `/login` y los webhooks |

**Aprobadores de prod:** `CG_PROD_APPROVERS=jrubio,jpordonez` en `infra/bootstrap/.env.ci`.

Decisiones:

- **Nadie del equipo tiene `Run/Replay` ni `Job/Configure`.** Los dos permiten ejecutar código propio dentro de un build, con acceso a las credenciales del pipeline.
- **`admin` puede aprobar cualquier `input`:** Jenkins no aplica `submitter` a los administradores. Por eso el pipeline valida además al aprobador contra `CG_PROD_APPROVERS` (`multibranchFlow.prodApprovalDecision`), y la respuesta de alguien que no está en la lista queda `INVALID`.
- **Cualquier integrante con `Job/Cancel` puede abortar la espera de prod.** Equivale a detener el build, y prod nunca se despliega con un *Abort*. Para que quede registrado quién decidió, se usa `RECHAZAR` en lugar de *Abort* (ver `PROD_APPROVAL_US31.md`).
- **Los webhooks `/github-webhook/` y `/sonarqube-webhook/` no piden sesión**, y el escaneo de ramas usa la credencial `github-token`. Activar la seguridad no rompe el disparo de builds ni el *quality gate* de US-10.

## 3. Cómo llegan las contraseñas a Jenkins

```text
bootstrap-ci.sh ──genera si faltan──> infra/bootstrap/.env.ci (0600, fuera de Git)
                                              │  --env-file
                                              ▼
docker-compose.ci.yml  secrets: JENKINS_PWD_* ──> /run/secrets/JENKINS_PWD_* (dentro del contenedor)
                                              │
cg-entrypoint.sh  ¿falta o está vacío alguno? ──sí──> no arranca (código 64)
                                              │ no
                                              ▼
jenkins/ci/jenkins.yaml  password: "${JENKINS_PWD_*}"  (JCasC lee /run/secrets)
```

- Las contraseñas llegan como **secretos de Compose** y no como variables de entorno. Así un `sh 'env'` de cualquier build no las imprime, y tampoco aparecen en `docker inspect`. Lo comprueba la prueba de la sección 6.
- `bootstrap-ci.sh` genera una contraseña aleatoria de 40 caracteres para cada cuenta que no tenga una. Nunca reemplaza las existentes y nunca las imprime. Si el `.env.ci` es anterior a US-31, le agrega las variables nuevas de la plantilla y conserva las suyas.
- El aprovisionamiento remoto (`--provision-aws`) nunca copia el `.env.ci` local, para no pisar las contraseñas del servidor.

| Archivo | Qué contiene |
|---|---|
| `jenkins/ci/jenkins.yaml` | Cuentas (`securityRealm`), matriz de permisos (`authorizationStrategy`) y variables globales `CG_*` |
| `docker-compose.ci.yml` | Secretos `JENKINS_*` y variables `CG_*` del contenedor |
| `infra/bootstrap/jenkins/cg-entrypoint.sh` | No arranca Jenkins si falta un secreto |
| `infra/bootstrap/jenkins/plugins.txt` | Agrega `matrix-auth` |
| `infra/bootstrap/.env.ci.example` | Plantilla: contraseñas vacías, aprobadores y hosts |
| `infra/bootstrap/bootstrap-ci.sh` | Genera las contraseñas que falten |
| `jenkins/test/validateJenkinsSecurity.sh` | 32 verificaciones estáticas (sección 6) |

## 4. Desplegar en el servidor de CI (`52.14.6.11`)

Se hace una sola vez, después de fusionar este cambio en `main`. El servidor no tiene un clon de Git: `bootstrap-ci.sh --provision-aws` copia `docker-compose.ci.yml`, `infra/bootstrap/` y `jenkins/ci/` a `/opt/circleguard-ci` y ejecuta allí el bootstrap.

1. **Respaldar** la configuración de Jenkins, por SSH. Revisa antes el espacio libre con `df -h /`, porque el disco ya se llenó una vez. Se excluyen los workspaces y las cachés, que se regeneran solos:

   ```bash
   ssh -i ~/.ssh/proyectoIngeClave.pem ec2-user@52.14.6.11
   sudo docker run --rm -v circleguard_jenkins_home:/data -v /home/ec2-user:/backup alpine \
     tar czf /backup/jenkins_home-$(date +%F).tgz -C /data \
       --exclude=./workspace --exclude=./caches --exclude=./.cache --exclude=./.gradle .
   ls -lh /home/ec2-user/jenkins_home-*.tgz
   ```

2. **Copiar los archivos nuevos y ejecutar el bootstrap.** Elige una de las dos opciones.

   - **Opción A, desde tu equipo** (recomendada; usa el mismo mecanismo con que se creó el servidor). Desde la raíz del repositorio, en `main` actualizado:

     ```bash
     bash infra/bootstrap/bootstrap-ci.sh --provision-aws --aws-profile personal --aws-region us-east-2 \
       --mode jenkins --ssh-key-path ~/.ssh/proyectoIngeClave.pem
     ```

     El script reutiliza la instancia `circleguard-ci-server` por su tag, sin crear otra. Luego copia los archivos sin tu `.env.ci` local y ejecuta el bootstrap en el servidor.

   - **Opción B, a mano, sin AWS CLI:**

     ```bash
     # en tu equipo, desde la raíz del repositorio en main actualizado:
     tar --exclude='infra/bootstrap/.env.ci' -czf - docker-compose.ci.yml infra/bootstrap jenkins/ci \
       | ssh -i ~/.ssh/proyectoIngeClave.pem ec2-user@52.14.6.11 "tar -C /opt/circleguard-ci -xzf -"
     # en el servidor:
     sudo bash /opt/circleguard-ci/infra/bootstrap/bootstrap-ci.sh --mode jenkins --public-host 52.14.6.11
     ```

   En cualquiera de las dos, el bootstrap:
   - agrega a `/opt/circleguard-ci/infra/bootstrap/.env.ci` las variables nuevas, conservando las existentes;
   - genera las 6 contraseñas;
   - reconstruye la imagen con `matrix-auth` y el entrypoint;
   - recrea el contenedor de Jenkins.

   El volumen con jobs, builds y credenciales no se toca.

3. **Verificar:**
   - `curl -s -o /dev/null -w '%{http_code}' http://52.14.6.11:8080/api/json` debe dar `403`;
   - en GitHub → *Settings → Webhooks*, la entrega más reciente debe tener respuesta `200`;
   - entra como `admin` y revisa que el job `circleguard-monorepo` siga ahí.

4. **Entregar las contraseñas** a cada integrante y al docente **por un canal privado**, nunca en el repositorio, Jira ni Discord:

   ```bash
   sudo grep -E '^JENKINS_(ADMIN_PASSWORD|PWD_)' infra/bootstrap/.env.ci
   ```

5. Cada integrante entra, va a *su usuario → Security → API Token → Add new token* y usa ese token, en vez de la contraseña, en scripts o en la CLI.

6. **Probar la compuerta:** ejecuta `main` y, cuando llegue a `Approve prod release`, aprueba con `jrubio` o `jpordonez`.

## 5. Operación

| Tarea | Cómo |
|---|---|
| Cambiar los aprobadores de prod | Edita `CG_PROD_APPROVERS` en `.env.ci` y ejecuta `docker compose ... up -d jenkins` |
| Cambiar una contraseña | Edita su variable en `.env.ci` y ejecuta `docker compose ... up -d --force-recreate jenkins`. Hace falta `--force-recreate` porque Compose no detecta cambios en el contenido de un secreto. Un cambio hecho desde la UI se pierde en el siguiente arranque, porque JCasC reaplica las contraseñas |
| Agregar una cuenta | Agrega el usuario y su entrada de permisos en `jenkins.yaml`, el secreto en `docker-compose.ci.yml` (`secrets` y `CG_REQUIRED_SECRETS`), la clave en `bootstrap-ci.sh` (`JENKINS_SECRET_KEYS`) y en `.env.ci.example`. `validateJenkinsSecurity` falla si alguno de los cinco no coincide |
| Recargar JCasC sin reiniciar | Como `admin`: *Manage Jenkins → Configuration as Code → Reload existing configuration* |

### Si nadie puede entrar

1. En el servidor, revisa por qué no arranca: `docker logs circleguard-jenkins | grep -E 'cg-entrypoint|SEVERE|ConfiguratorException'`. Si aparece `Faltan secretos de Jenkins`, completa `.env.ci` y vuelve a crear el contenedor.
2. Si la contraseña de `admin` se perdió, define una nueva en `JENKINS_ADMIN_PASSWORD` y ejecuta `up -d --force-recreate jenkins`. JCasC la aplica al arrancar.
3. Último recurso: restaura el respaldo del paso 4.1. Los jobs, builds y credenciales viven en el volumen, no en la configuración de seguridad.

## 6. Pruebas

| Prueba | Resultado |
|---|---|
| `bash jenkins/test/validateJenkinsSecurity.sh` (o `./gradlew validateJenkinsSecurity`) | 32 verificaciones: cuentas sin registro público, ninguna contraseña en texto plano, solo `admin` con `Administer`, anónimo sin permisos, nadie con `Run/Replay` ni `Job/Configure`, aprobadores existentes y distintos de admin y docente, y la misma lista de secretos en los cinco archivos. Se comprobó que falla con 6 configuraciones inseguras (contraseña en texto plano, `allowsSignup: true`, `Administer` a un integrante, permisos al anónimo, `Run/Replay` y una cuenta sin secreto) |
| `bash infra/bootstrap/test-bootstrap-ci-idempotency.sh` | 65 pruebas, 26 de ellas de US-31: generación de las 6 contraseñas, que no aparezcan en el log, que la segunda ejecución no las cambie, actualización de un `.env.ci` anterior y el entrypoint que se niega a arrancar |
| **Jenkins 2.580.2 real** con el `docker-compose.ci.yml`, el `jenkins.yaml`, los plugins y el entrypoint de este repositorio (10 de noviembre de 2026) | 34 verificaciones (detalle abajo), más 4 escenarios |

Las 34 verificaciones en el Jenkins real comprobaron que:

- **Anónimo:** recibe 403 en la API, en los jobs y en la consola de scripts.
- **Webhooks:** `/github-webhook/` y `/sonarqube-webhook/` responden sin sesión.
- **Registro y credenciales:** `/signup` no existe, y una contraseña incorrecta o un usuario inexistente reciben 401.
- **Integrantes:** leen y lanzan builds, pero no abren la consola de scripts, *Manage Jenkins*, las credenciales ni la configuración del job.
- **`docente`:** lee, pero no lanza builds ni aborta.
- **Variables:** `CG_PROD_APPROVERS` llega como variable global y ninguna contraseña está en el entorno del proceso ni en un `sh 'env'`.
- **Aprobación:**
  - `ecuellar` y `docente` no pueden aprobar;
  - `jrubio` aprueba y queda registrado como `APPROVER=jrubio`;
  - `admin` puede aprobar en Jenkins, por eso el pipeline valida la lista;
  - un integrante puede abortar la espera, y prod no se despliega.

Los 4 escenarios adicionales:

1. Tras un reinicio se conservan las cuentas, los permisos y los builds.
2. Si falta una contraseña en `.env.ci`, Compose no crea el contenedor.
3. Si una contraseña está vacía, el entrypoint termina con código 64 y nombra el secreto.
4. **Actualización desde un Jenkins sin seguridad, como el servidor actual:** antes, el anónimo recibía 200 en `/api/json` y `useSecurity` era `false`. Después recibe 403, las cuentas funcionan y el job multibranch se conserva.
