# Kubernetes — namespaces, middleware y microservicios (US-21, US-37)

Manifiestos de Kustomize para el clúster k3s de cada ambiente (US-20). Cada overlay crea el namespace `circleguard-<env>` con sus políticas y despliega el middleware de CircleGuard: PostgreSQL, Neo4j, Zookeeper, Kafka, Redis y OpenLDAP.

| Carpeta | Contenido |
|---|---|
| `base/namespace/` | `Namespace` con Pod Security `baseline`, `ResourceQuota`, `LimitRange` y `NetworkPolicy` (niega la entrada y solo permite el tráfico del mismo namespace) |
| `base/services/` | Los 8 microservicios (US-37): un `Deployment` y un `Service` por cada uno, sus ConfigMaps y el `Ingress` `circleguard-api` (Traefik) |
| `base/middleware/` | Un `StatefulSet` y un `Service` headless por componente, con las imágenes de `deploy/compose`, probes, recursos y volumen persistente. Incluye una copia de `init-db.sql` |
| `components/prod-sizing/` | Límites de `docker-compose.prod.yml` y memoria de las JVM, compartidos por stage y prod |
| `overlays/{dev,stage,prod}/` | Namespace, etiqueta de ambiente, parámetros (dominio LDAP, retención de Kafka) y tamaño de los discos |
| `scripts/` | `validate.sh`, `get-kubeconfig.sh`, `create-secrets.sh`, `deploy-middleware.sh` y `lib.sh` |

## Uso

```bash
# Validar sin clúster ni credenciales (lo mismo que corre Jenkins)
bash deploy/k8s/scripts/validate.sh

# Desplegar en el clúster de un ambiente
export AWS_PROFILE=<perfil>
bash deploy/k8s/scripts/get-kubeconfig.sh --env dev
export KUBECONFIG=~/.kube/circleguard-dev.yaml
bash infra/bootstrap/inject-jenkins-secrets.sh --env dev --output /tmp/cg-dev.env
bash deploy/k8s/scripts/deploy-middleware.sh --env dev --env-file /tmp/cg-dev.env
```

Las contraseñas no están en Git: `create-secrets.sh` crea los Secrets `circleguard-middleware` y `circleguard-app` (llaves de JWT, QR y la bóveda) a partir del `.env` del inyector (US-05) o de variables de entorno.

Los microservicios (US-37) viven en el mismo namespace y usan los mismos nombres que en compose: `postgres:5432`, `neo4j:7687`, `kafka:29092`, `redis:6379` y `openldap:389`. El cliente web (`web-client:8080`) también está en el namespace porque lo usan los E2E de la compuerta de promoción (`run-e2e.sh --k8s`), que reescriben su `runtime-config.js` con los port-forward. No va en el Ingress `circleguard-api`, que solo publica las APIs: se llega a él con `kubectl port-forward`. Su imagen y versión las fija el release:

```bash
REGISTRY_URL=<registro> bash deploy/scripts/k8s-deploy.sh deploy --env dev --version X.Y.Z
bash deploy/scripts/k8s-deploy.sh verify --env dev --version X.Y.Z
curl -H 'Host: api.dev.circleguard.edu' http://<IP del nodo>/api/v1/...
```

Diseño y prueba de los microservicios: [`docs/arquitectura/DESPLIEGUE_SERVICIOS_K8S_US37.md`](../../docs/arquitectura/DESPLIEGUE_SERVICIOS_K8S_US37.md).

Diseño, parámetros por ambiente, seguridad y evidencias: [`docs/arquitectura/KUBERNETES_PLATAFORMA_US21.md`](../../docs/arquitectura/KUBERNETES_PLATAFORMA_US21.md).
