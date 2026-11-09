# US-08 — docker-compose por ambiente con healthchecks y versionado SemVer estricto

Archivos de orquestación de la pila completa de CircleGuard por ambiente:

| Archivo | Ambiente | Proyecto compose | Red |
|---|---|---|---|
| [`deploy/compose/docker-compose.dev.yml`](../../deploy/compose/docker-compose.dev.yml) | dev | `circleguard-dev` | `circleguard_dev_net` |
| [`deploy/compose/docker-compose.stage.yml`](../../deploy/compose/docker-compose.stage.yml) | stage | `circleguard-stage` | `circleguard_stage_net` |
| [`deploy/compose/docker-compose.prod.yml`](../../deploy/compose/docker-compose.prod.yml) | prod | `circleguard-prod` | `circleguard_prod_net` |

Cada archivo es autocontenido y despliega **12 contenedores**:

- **Middleware:** PostgreSQL 16.4, Neo4j 5.26.0, Zookeeper y Kafka (cp 7.6.0), Redis 7.2.5 y OpenLDAP 1.5.0.
- **Servicios núcleo:** `auth-service`, `identity-service`, `promotion-service`, `form-service` y `gateway-service`, con las imágenes de US-06.
- **Cliente web:** `web-client`, con la imagen de US-07.

> El `docker-compose.dev.yml` de la raíz se conserva: es el middleware que usan `bootRun`, `bootstrap-env.sh --start-middleware` (US-05) y `scripts/docker/verify-images.sh` (US-06).

## CA2 — Versionado semántico estricto, nunca `latest`

Las imágenes propias se referencian siempre como:

```
${REGISTRY_URL}/circleguard/<servicio>:${IMAGE_TAG}
```

- `IMAGE_TAG` debe seguir SemVer 2.0 (por ejemplo `1.2.0` o `1.3.0-rc.1`). Si no está definido se usa `APP_VERSION`, que es la variable que ya genera US-05: `${IMAGE_TAG:-${APP_VERSION:?...}}`.
- Si faltan los dos, `docker compose` **falla**. No hay ningún valor por defecto que pueda resolver a `latest`.
- `inject-jenkins-secrets.sh` rechaza un `IMAGE_TAG`/`APP_VERSION` que no sea SemVer, como `latest`.
- Las imágenes de terceros también están fijadas a una versión exacta.
- `<servicio>` ∈ `auth-service`, `identity-service`, `promotion-service`, `form-service`, `gateway-service` y `web-client`, igual que en `scripts/docker/build-images.sh`.

## CA3 — Healthchecks y orden de arranque

| Contenedor | Healthcheck (funcional) |
|---|---|
| postgres | `pg_isready` por TCP y `SELECT 1` sobre `circleguard_auth`, lo que confirma que `init-db.sql` ya se ejecutó |
| neo4j | `cypher-shell 'RETURN 1'` sobre Bolt con las credenciales de `NEO4J_AUTH` |
| zookeeper | comando `srvr` (4lw) que responde `Mode` |
| kafka | `kafka-broker-api-versions` contra el listener interno |
| redis | `redis-cli ping` autenticado (`REDISCLI_AUTH`) que responde `PONG` |
| openldap | `ldapwhoami` con bind autenticado de `cn=admin,${LDAP_BASE_DN}` |
| 5 servicios núcleo | `GET /actuator/health/readiness`, con un grupo readiness que incluye sus dependencias (ver abajo) |
| web-client | `GET /healthz`, más la comprobación de que el entrypoint generó `/runtime-config.js` |

Grupo `readiness` de Actuator, configurado por variable de entorno:

| Servicio | Componentes del grupo `readiness` |
|---|---|
| auth | `readinessState`, `db`, `ldap` |
| identity | `readinessState`, `db` |
| promotion | `readinessState`, `db`, `neo4j`, `redis` |
| form | `readinessState`, `db` |
| gateway | `readinessState`, `redis` |

Así, un servicio solo pasa a `healthy` cuando también alcanza sus dependencias.

Orden de arranque. Todas las aristas usan `condition: service_healthy`:

```
zookeeper ──► kafka
postgres, kafka ──────────────► identity-service
postgres, openldap, identity ─► auth-service
postgres, neo4j, kafka, redis ► promotion-service
postgres, kafka ──────────────► form-service
redis ────────────────────────► gateway-service
auth, identity, promotion, form, gateway ─► web-client
```

## Diferencias entre ambientes

| Aspecto | dev | stage | prod |
|---|---|---|---|
| Origen de las imágenes propias | `build:` local o registro | solo registro (sin `build:`) | solo registro (sin `build:`) |
| Middleware publicado en el host | sí (5432, 7474/7687, 9092, 6379, 389/636) | no | no |
| Puertos por defecto (auth/identity/promotion/form/gateway/web) | 8180/8083/8088/8086/8087/8080 | +1000 (9180 … 9080) | +2000 (10180 … 10080) |
| `restart` | `unless-stopped` | `always` | `always` |
| Límites de CPU y memoria (`deploy.resources.limits`) | — | sí | sí |
| `no-new-privileges` en imágenes propias | — | sí | sí |
| Logs `json-file` | 10m × 3 | 10m × 3 | 50m × 5 |
| `LDAP_DOMAIN`, `LDAP_BASE_DN` y `PUBLIC_HOST` | con valor por defecto | obligatorios | obligatorios |

Los puertos desplazados permiten que varios ambientes compartan un mismo nodo (el fallback de cuota de US-05) sin colisiones. Por la misma razón ningún servicio fija `container_name`.

## Configuración de los servicios

Los `application.yml` no se modifican. Cada valor se sobrescribe por variable de entorno, con el binding relajado de Spring:

| Variable de compose | Propiedad de Spring | Servicios |
|---|---|---|
| `SPRING_DATASOURCE_URL`/`USERNAME`/`PASSWORD` | `spring.datasource.*` | auth, identity, promotion, form |
| `SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka:29092` | `spring.kafka.bootstrap-servers` | identity, promotion, form |
| `SPRING_NEO4J_URI` y `SPRING_NEO4J_AUTHENTICATION_*` | `spring.neo4j.*` | promotion |
| `SPRING_DATA_REDIS_HOST`/`PORT`/`PASSWORD` | `spring.data.redis.*` | promotion, gateway |
| `SPRING_LDAP_URLS`/`BASE`/`USERNAME`/`PASSWORD` | `spring.ldap.*` | auth |
| `IDENTITY_SERVICE_URL` | `identity.service.url` | auth |
| `QR_EXPIRATION` (`${QR_EXPIRATION_MS:-60000}`, en ms) | `qr.expiration` | auth. Corrige el `300` (0,3 s) del `application.yml`; ver US-13 |
| `JWT_SECRET` y `QR_SECRET` | `jwt.secret` y `qr.secret` | auth, identity, promotion, gateway |
| `VAULT_SECRET`, `VAULT_SALT` y `VAULT_HASHSALT` | `vault.secret`, `vault.salt` y `vault.hash-salt` | identity |

Cambios de código necesarios en auth-service. Los valores por defecto son los mismos de antes, así que `bootRun` local sigue funcionando:

- `SecurityConfig#contextSource` leía `localhost:389` y las credenciales de forma fija. Ahora usa `spring.ldap.*`.
- `IdentityClient` llamaba a `http://localhost:8083` de forma fija. Ahora usa `identity.service.url`.

Kafka expone dos listeners: `INTERNAL://kafka:29092` para los contenedores y `EXTERNAL://${KAFKA_ADVERTISED_HOST}:9092` para el host. En stage y prod el externo no se publica.

## Variables de entorno

El `.env` de cada ambiente lo genera el mismo inyector de US-05, que ahora también escribe `IMAGE_TAG`, `LDAP_BASE_DN`, `PUBLIC_HOST` y, opcionalmente, `INIT_DB_SCRIPT`:

```bash
IMAGE_TAG=1.2.0 PUBLIC_HOST=<ip-publica> \
  bash infra/bootstrap/inject-jenkins-secrets.sh --env stage --output deploy/compose/.env.stage
```

Los archivos `deploy/compose/.env*` están en `.gitignore`. Las plantillas están en `infra/bootstrap/env/.env.<env>.example` y en `.env.example`.

`bootstrap-env.sh` (US-05) copia `deploy/compose/docker-compose.<env>.yml` a `/opt/circleguard/<env>/compose/stack/` y lo valida con `docker compose config -q` usando el `.env` del ambiente. **No lo levanta**: el despliegue y la promoción corresponden al pipeline (US-13). En el nodo, `INIT_DB_SCRIPT` apunta a `/opt/circleguard/<env>/compose/init-db.sql`.

## Uso

```bash
# dev: construir con tag SemVer y levantar
bash infra/bootstrap/inject-jenkins-secrets.sh --env dev --output deploy/compose/.env.dev
IMAGE_TAG=1.2.0 docker compose --env-file deploy/compose/.env.dev -f deploy/compose/docker-compose.dev.yml build
IMAGE_TAG=1.2.0 docker compose --env-file deploy/compose/.env.dev -f deploy/compose/docker-compose.dev.yml up -d --wait

# stage/prod: consumir imágenes publicadas
docker compose --env-file /opt/circleguard/stage/.env \
  -f /opt/circleguard/stage/compose/stack/docker-compose.stage.yml up -d --wait
```

Si el host ya ocupa algún puerto, se puede sobrescribir con una variable de shell, que tiene prioridad sobre el `.env`. Por ejemplo, `POSTGRES_PORT=15432`.

## Validación (subtarea 3)

| Comando | Qué verifica |
|---|---|
| `bash deploy/compose/validate-compose.sh` o `./gradlew validateComposeEnvironments` | Por cada ambiente: renderizado, 12 servicios (CA1), sin `:latest` ni imágenes sin tag, imágenes propias que resuelven exactamente a `${REGISTRY_URL}/circleguard/<svc>:${IMAGE_TAG}` SemVer, falla sin `IMAGE_TAG`/`APP_VERSION` (CA2), healthcheck en los 12 contenedores, 18 aristas `service_healthy` y el orden de arranque esperado (CA3), sin `container_name`; en stage/prod, middleware sin puertos y falla sin secretos |
| `bash deploy/compose/smoke-up.sh [dev\|stage\|prod]` | Levantamiento real: build (dev) o pull, `up --wait`, 12/12 `healthy`, sin `:latest` en ejecución, sondeo HTTP desde el host (dev) y `down -v` (`KEEP_UP=1` deja la pila arriba) |

Necesita docker compose v2 y `jq`. Si `jq` no está instalado, se usa `ghcr.io/jqlang/jq:1.7.1`.
