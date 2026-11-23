# US-37 — Despliegue de los ocho microservicios con ConfigMaps, Secrets e Ingress

| | |
|---|---|
| Historia | US-37 (SCRUM-120, 5 SP) |
| Alcance | Los 8 microservicios de CircleGuard en Kubernetes, con su configuración fuera de la imagen y un Ingress por ambiente |
| Relación | Se monta sobre el namespace y el middleware de [US-21](KUBERNETES_PLATAFORMA_US21.md). La imagen y la versión las fija el release de US-39 (`deploy/scripts/k8s-deploy.sh`). Las probes y el autoscaling son US-38; TLS, RBAC y endurecimiento de Secrets son US-26. |
| Código | [`deploy/k8s/base/services/`](../../deploy/k8s/base/services), los overlays de [`deploy/k8s/overlays/`](../../deploy/k8s/overlays) y [`deploy/k8s/scripts/`](../../deploy/k8s/scripts) |

## 1. Idea en una frase

Cada microservicio corre como un **Deployment** (los pods) detrás de un **Service** (una dirección interna fija). Lo que cambia entre ambientes no está en la imagen: viene de **ConfigMaps** (valores normales) y **Secrets** (contraseñas y llaves). Un **Ingress** es la única puerta de entrada desde afuera y reparte cada URL al microservicio que la atiende.

```
Internet ──► Traefik (Ingress de k3s) ──► api.<env>.circleguard.edu/api/v1/...
                                              │
       /api/v1/auth, /users ──────────────────┼──► auth-service:8180 ──► postgres, openldap, identity-service
       /api/v1/identities ────────────────────┼──► identity-service:8083 ──► postgres, kafka
       /api/v1/circles, /encounters, ... ─────┼──► promotion-service:8088 ──► postgres, neo4j, kafka, redis
       /api/v1/surveys, /certificates, ... ───┼──► form-service:8086 ──► postgres, kafka
       /api/v1/gate ──────────────────────────┼──► gateway-service:8087 ──► redis
       /api/v1/analytics ─────────────────────┼──► dashboard-service:8084 ──► postgres, promotion-service
       /api/v1/files ─────────────────────────┘──► file-service:8085 ──► volumen file-uploads
                          (sin ruta pública)       notification-service:8082 ──► kafka, auth, identity
```

## 2. Criterios de aceptación

| Criterio | Cómo se cumple | Evidencia |
|---|---|---|
| **CA1.** Los ocho microservicios se despliegan con Helm, Kustomize o manifiestos versionados | Kustomize, igual que el middleware de US-21: `deploy/k8s/base/services/` tiene un archivo por microservicio (Deployment + Service) y la base lo incluye, así que cada overlay (`dev`, `stage`, `prod`) despliega middleware y microservicios juntos. | `validate.sh` exige los 8 Deployments y Services en cada ambiente; §4 |
| **CA2.** ConfigMaps y Secrets parametrizados por ambiente, sin secretos en el repositorio | ConfigMap `services-config` (perfil, ambiente, nivel de log, direcciones de Kafka y Redis) que cada overlay reemplaza; un ConfigMap `<servicio>-config` con las URL de sus dependencias; el dominio LDAP sale de `middleware-config` del ambiente. Las contraseñas y llaves vienen de los Secrets `circleguard-middleware` y `circleguard-app`, que `create-secrets.sh` crea desde el `.env` del inyector (US-05). En Git no hay ningún Secret. | `validate.sh`: ningún Secret en el render, contraseñas solo por `secretKeyRef`, ninguna variable sensible con valor literal; §4 |
| **CA3.** El Ingress expone los endpoints definidos y el despliegue se repite en dev, stage y prod | Ingress `circleguard-api` con Traefik (viene con k3s), un host por ambiente (`api.dev`, `api.stage`, `api.prod.circleguard.edu`) y una ruta por cada prefijo `/api/v1/...` de los controladores. El mismo `k8s-deploy.sh deploy --env <env> --version X.Y.Z` despliega cualquier ambiente. | `validate.sh` revisa host y rutas en los 3 overlays; §4 |

## 3. Decisiones de diseño

| Decisión | Motivo |
|---|---|
| **Kustomize, no Helm** | US-21 ya usa Kustomize y `k8s-deploy.sh` (US-39) arma el release encima del overlay. Agregar Helm sería una segunda herramienta para lo mismo. |
| **Mismos nombres y puertos que en compose** | `auth-service:8180`, `identity-service:8083`, etc. El código y las variables de compose (US-08) sirven sin cambios. |
| **Un ConfigMap común y uno por servicio** | Lo común (perfil, ambiente, Kafka, Redis) se escribe una vez y cada overlay solo cambia lo suyo. Lo propio de cada servicio (su base de datos, a quién llama) queda junto. |
| **Kustomize pone un hash en el nombre del ConfigMap** | `services-config-d2tmbd6cg4`. Si cambia un valor, cambia el nombre, el Deployment cambia y Kubernetes reinicia los pods con la configuración nueva. Sin eso, los pods seguirían con la vieja. |
| **Dos Secrets y solo las llaves necesarias** | `circleguard-middleware` (contraseñas de bases, de US-21) y `circleguard-app` (JWT, QR y bóveda). Cada pod recibe con `secretKeyRef` solo lo que usa: `form-service` no ve el JWT y solo `identity-service` ve las llaves de la bóveda. |
| **Un host por ambiente y rutas por prefijo** | Un solo nombre para el cliente web. Se publican solo los prefijos `/api/v1/...`: `/actuator`, el middleware y `notification-service` (no tiene API) quedan dentro del clúster. |
| **NetworkPolicy `allow-ingress-controller`** | `default-deny-ingress` de US-21 bloquea también a Traefik, que vive en `kube-system`. Esta política solo deja pasar a Traefik hacia el puerto `http` de los microservicios. |
| **Contenedor endurecido** | Usuario 10001 (el de los Dockerfiles), sin escalar privilegios, sin capacidades, disco de solo lectura con `/tmp` en memoria, sin token de la API. Va escrito en cada archivo porque Trivy (US-38) revisa cada YAML tal cual. |
| **Recursos y `maxSurge: 0`** | 100m/384Mi pedidos y 500m/768Mi de límite por servicio. Con el middleware de prod, el namespace pide 1600m de 1800m de CPU y 5952Mi de 6Gi de memoria. Un pod extra por servicio durante una actualización pasaría la cuota, así que se reemplaza el pod en lugar de sumar uno. |
| **Volumen `file-uploads` para `file-service`** | Guarda los archivos en `/app/uploads`; con un PVC de 1 Gi no se pierden al reiniciar. Cabe en la cuota de los 3 ambientes (10 de 12, 15 de 18 y 24 de 28 Gi). |
| **Imagen `circleguard/<servicio>:0.1.0` en Git** | Es el último release. `k8s-deploy.sh` la reemplaza por `<registro>/circleguard/<servicio>:<versión>` en cada despliegue; `validate.sh` exige que nunca sea `latest`. |

## 4. Prueba en un clúster k3s local

Se levantó k3s `v1.37.2+k3s1` (la versión de US-20, con su Traefik) con `k3d` en la máquina de un integrante. Se construyeron las 8 imágenes con sus Dockerfiles, se importaron al clúster y se siguió el mismo camino que usará Jenkins: `inject-jenkins-secrets.sh` → `deploy-middleware.sh --env dev` (crea los dos Secrets) → `k8s-deploy.sh deploy --env dev --version 0.1.0` → `k8s-deploy.sh verify`.

| Prueba | Resultado |
|---|---|
| `validate.sh` (dev, stage, prod) | 47 recursos por ambiente, esquema válido con kubeconform y todas las reglas en verde |
| Trivy `config` sobre `deploy/k8s` (HIGH y CRITICAL) | 0 hallazgos |
| `k8s-deploy.sh verify` | `Rollout completo: 14 recursos listos con la versión 0.1.0` (8 Deployments y 6 StatefulSets) |
| `/actuator/health` dentro de cada pod | Los 8 responden `UP`; `promotion-service` tarda unos 130 s en arrancar con 500m de CPU |
| Configuración del ambiente | En `auth-service`: `SPRING_PROFILES_ACTIVE=dev`, `SPRING_LDAP_BASE=dc=dev,dc=circleguard,dc=edu` (tomado de `middleware-config`) e `IDENTITY_SERVICE_URL=http://identity-service:8083` |
| Mínimo privilegio en Secrets | `auth-service` no tiene ninguna variable `VAULT_*`; `form-service` no tiene JWT, QR ni bóveda |
| Ingress, host `api.dev.circleguard.edu` | Cada ruta llega a su servicio: `/api/v1/auth/login` → 405 de Spring (pide POST), `/api/v1/identities` → 401, `/api/v1/circles`, `/surveys`, `/gate/validate` → 405 de Spring, `/api/v1/analytics/summary` → 200 con datos |
| Lo que no se publica | `/actuator/health` y `/api/v1/notifications` → `404 page not found` de Traefik; con el host de prod → 404 |
| Volumen de `file-service` | Se subió un archivo por el Ingress (`POST /api/v1/files/upload`), se reinició el Deployment y el archivo seguía en `/app/uploads` |
| Contenedor endurecido | `id` → `uid=10001(circleguard)`; `touch /app/x` → `Read-only file system` |
| Aislamiento | Desde otro namespace, `auth-service:8180` queda **BLOQUEADO**; desde `circleguard-dev` responde `UP` |
| Cuota de dev en uso | 1325m de 1800m de CPU pedida, 4992Mi de 6Gi de memoria y 10 de 12 Gi de volúmenes |

**Comportamiento esperado.** Mientras Kafka crea los topics, `promotion-service` registra avisos `LEADER_NOT_AVAILABLE` y `notification-service` puede reiniciarse una vez; ambos quedan bien solos. Sin probes (US-38), Kubernetes marca el pod como listo apenas arranca el proceso, no cuando Spring termina de iniciar.

## 5. Operación

| Tarea | Cómo |
|---|---|
| Desplegar una versión | `REGISTRY_URL=<registro> bash deploy/scripts/k8s-deploy.sh deploy --env <env> --version X.Y.Z` y luego `verify` |
| Cambiar un valor de configuración | Editar el overlay (o `base/services/kustomization.yaml`) y volver a desplegar: el hash nuevo reinicia los pods afectados |
| Rotar una llave | Regenerar el `.env` con el inyector, `create-secrets.sh --env <env> --env-file <.env>` y `kubectl -n circleguard-<env> rollout restart deployment` |
| Probar una ruta | `curl -H 'Host: api.<env>.circleguard.edu' http://<IP del nodo>/api/v1/...` |
| Ver el estado | `kubectl -n circleguard-<env> get deploy,pods,svc,ingress` |

## 6. Pendiente

- **Desplegar en los clústeres de AWS:** depende del `apply` de US-20 y de que los nodos k3s puedan descargar del registro (Nexus en HTTP necesita `registries.yaml` en k3s). La configuración ya se probó en local (§4).
- **DNS:** los hosts `api.<env>.circleguard.edu` no existen todavía; mientras tanto se usa la cabecera `Host` o una entrada en `/etc/hosts`.
- **US-38:** readiness y liveness probes de los microservicios y autoscaling.
- **US-26:** TLS en el Ingress, RBAC y cifrado o rotación de Secrets.
- **`notification-service`:** no hay servidor SMTP en el clúster; el correo queda configurable con `SPRING_MAIL_HOST` cuando exista uno.
