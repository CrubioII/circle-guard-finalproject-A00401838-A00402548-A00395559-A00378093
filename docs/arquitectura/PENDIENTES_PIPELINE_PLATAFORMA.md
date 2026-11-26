# Pendientes de la plataforma y el pipeline

Arreglos que salieron en la primera ejecución real de Terraform y Kubernetes desde Jenkins (builds 39 a 43 de `main`, noviembre de 2026). Ninguno impide que el pipeline termine en verde; se dejaron para después porque la prioridad era cerrar el flujo dev, stage y prod.

## 1. Estado que se hizo a mano y no está en código

Hay que tenerlo en cuenta antes de recrear un nodo o un ambiente.

| Qué | Dónde | Por qué | Pendiente que lo reemplaza |
|---|---|---|---|
| `/etc/rancher/k3s/registries.yaml` con `18.117.90.15:5000` por HTTP | Los 3 servers k3s, por Session Manager | Nexus sirve por HTTP y containerd intentaba HTTPS (`ImagePullBackOff`) | P2 |
| Secrets `circleguard-middleware` y `circleguard-app` con valores aleatorios | Los 3 namespaces `circleguard-<env>`, por Session Manager | El pipeline no los crea y los pods de middleware no arrancaban (`CreateContainerConfigError`) | P3 |
| Namespaces `circleguard-stage` y `circleguard-prod` creados antes del primer despliegue | Servers de stage y prod | Los Secrets necesitan el namespace; `kubectl apply -k` lo adopta después | Ninguno |
| Instancias `circleguard-env-dev`, `-stage` y `-prod` de US-05 detenidas | EC2 | La cuota de vCPU (8) no alcanzaba para los servers de Terraform; AWS rechazó el aumento | P9 |
| Variable global `CG_TF_STATE_BUCKET` | Jenkins | Desbloqueó el build 39 antes del fix de #77 | Se puede borrar |

## 2. PR pendientes

| # | Historia | Problema | Arreglo propuesto | Prioridad |
|---|---|---|---|---|
| P1 | US-12 (**resuelto**: `GITHUB_CREDENTIALS_ID`, `git fetch --tags` antes de calcular y `git push` del tag en `runReleaseNotesAndTagStage`) | Los tags `vX.Y.Z` no llegan a GitHub (`git ls-remote --tags origin` está vacío). En un workspace nuevo (`main@2`), `calculate-semver.sh` no ve tags, vuelve a `0.1.0` y se publican imágenes `0.1.0` encima de las anteriores (build 43) | Revisar por qué falla o no corre `git push origin <tag>` en `git-tag-release.sh`; hacer `git fetch --tags` antes de calcular la versión | Alta |
| P2 | US-20 / US-22 (**resuelto**: variable `insecure_registries`; el server existente ignora el launch template y no se reinicia) | Las plantillas `server.sh.tftpl` y `agent.sh.tftpl` no escriben `registries.yaml`; un nodo nuevo no puede bajar imágenes de Nexus | Variable `insecure_registries` en el módulo `compute` y escribir el archivo antes de instalar k3s. El cambio de `user_data` detiene y enciende cada server una vez (no se vuelve a ejecutar) | Alta |
| P3 | US-21 / US-22 (**resuelto**, sin dar acceso a Secrets a Jenkins: `create-secrets.sh --generate --if-missing` para el administrador y `k8s-deploy.sh verify` nombra los pods en `CreateContainerConfigError`) | El pipeline no crea los Secrets; un ambiente nuevo falla en `Verify <env> health` | Credenciales en Jenkins por ambiente y un paso antes de `Deploy to <env>` que corra `create-secrets.sh` solo si faltan. Respaldar antes las claves que ya están en los clústeres | Alta |
| P4 | US-22 / US-28 | Si `verify` falla, el rollback espera sin límite: el build 42 quedó colgado 65 min hasta el timeout del pipeline | Tope de tiempo en `k8s-deploy.sh rollback` (`--timeout` en `rollout status`) y en la etapa | Media |
| P5 | US-22 | Los PR usan la misma credencial `aws-terraform` que el apply, y un PR puede cambiar el `Jenkinsfile` | Plan con `circleguard-terraform` (lectura) y apply con una credencial `aws-terraform-apply` solo en las etapas de `main` | Media |
| P6 | US-22 | La imagen de Jenkins del servidor de CI es anterior al commit que instala kubectl; hoy se descarga en cada workspace | `bootstrap-ci.sh --mode jenkins` en el servidor de CI (reinicia Jenkins) | Baja |
| P7 | US-22 | La guía `docs/arquitectura/GUIA_APPLY_TERRAFORM_US22.md` (política, usuario, credencial, primer apply) existe solo en local | Subirla en un PR de documentación | Baja |
| P8 | Documentación | En los documentos y comentarios del repo, US-38 es Trivy y US-39 es el despliegue en Kubernetes. En Jira, US-38 es HPA y sondas, US-39 es Trivy y el despliegue es el CA3 de US-22 | Corregir `PIPELINE_PLATAFORMA_US22_US38_US39.md`, el `Jenkinsfile` y `platformFlow.groovy` | Baja |
| P9 | US-05 | Las 3 instancias de US-05 detenidas siguen cobrando sus discos EBS | Decidir si se terminan; si se terminan, el despliegue `compose` deja de tener destino | Baja |
| P10 | US-37 | El web-client recibe la etiqueta `component: backend` y los recursos de los servicios Spring (384 Mi pedidos) por el parche común; no hay Ingress | Etiqueta `frontend`, recursos propios y el Ingress de US-37 | Baja |
| P11 | US-39 (Jira) | `Trivy Image Scan` reporta CVE HIGH/CRITICAL en las imágenes (desde #73 no bloquea) | Actualizar la imagen base de nginx del web-client y Spring Boot | Media |
| P12 | Seguridad | Falso positivo de GitGuardian (incidente 39834339) | Marcarlo en el panel de GitGuardian | Baja |

## 3. Comportamientos que conviene saber

- El primer `Terraform Apply stage` y `Terraform Apply prod` desde Jenkins corrige el `user_data` a LF (el primer apply se hizo desde Windows). AWS detiene y enciende el server unos 30 s; conserva su IP elástica.
- La API de cada clúster (6443) solo acepta la VPC y `TF_VAR_compute_api_allowed_cidrs` (la IP de Jenkins). Para inspeccionar un clúster sin Jenkins: EC2, `Connect`, Session Manager y `sudo k3s kubectl ...`.
