# Kubernetes — namespaces y middleware (US-21)

Manifiestos de Kustomize para el clúster k3s de cada ambiente (US-20). Cada overlay crea el namespace `circleguard-<env>` con sus políticas y despliega el middleware de CircleGuard: PostgreSQL, Neo4j, Zookeeper, Kafka, Redis y OpenLDAP.

| Carpeta | Contenido |
|---|---|
| `base/namespace/` | `Namespace` con Pod Security `baseline`, `ResourceQuota`, `LimitRange` y `NetworkPolicy` (niega la entrada y solo permite el tráfico del mismo namespace) |
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

Las contraseñas no están en Git: `create-secrets.sh` crea el Secret `circleguard-middleware` a partir del `.env` del inyector (US-05) o de variables de entorno.

Los servicios de CircleGuard (US-37) se despliegan en el mismo namespace y usan los mismos nombres que en compose: `postgres:5432`, `neo4j:7687`, `kafka:29092`, `redis:6379` y `openldap:389`.

Diseño, parámetros por ambiente, seguridad y evidencias: [`docs/arquitectura/KUBERNETES_PLATAFORMA_US21.md`](../../docs/arquitectura/KUBERNETES_PLATAFORMA_US21.md).
