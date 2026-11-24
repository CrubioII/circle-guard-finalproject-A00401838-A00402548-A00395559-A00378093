# US-38 — Autoscaling y sondas de salud de los microservicios

| | |
|---|---|
| Historia | US-38 |
| Alcance | `startupProbe`, `livenessProbe` y `readinessProbe` en cada microservicio y `HorizontalPodAutoscaler` en los servicios del camino caliente |
| Relación | Se monta sobre los Deployments de US-37 y la cuota del namespace de US-21. El clúster k3s de US-20 trae metrics-server, que alimenta los HPA. |
| Código | [`deploy/k8s/base/services/autoscaling.yaml`](../../deploy/k8s/base/services/autoscaling.yaml), el patch de sondas en [`base/services/kustomization.yaml`](../../deploy/k8s/base/services/kustomization.yaml) y las comprobaciones de US-38 en [`scripts/validate.sh`](../../deploy/k8s/scripts/validate.sh) |

## 1. Sondas

Las tres sondas usan los grupos de salud de Spring Boot Actuator en el puerto `http` de cada contenedor. Ya estaban activos (`MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true`) y no piden token. Van en un solo patch de Kustomize para todos los Deployments, así que un servicio nuevo de US-37 las recibe sin tocar nada.

| Sonda | Endpoint | Ritmo | Qué pasa si falla |
|---|---|---|---|
| `startupProbe` | `/actuator/health/liveness` | cada 10 s, hasta 30 veces (5 min) | Las otras dos no empiezan hasta que pase. Con 500m de CPU la JVM tarda; 5 minutos coincide con el `ROLLOUT_TIMEOUT` de `k8s-deploy.sh verify`. |
| `livenessProbe` | `/actuator/health/liveness` | cada 20 s, 3 fallos | kubelet reinicia el contenedor. Solo mira el estado interno de la app: si mirara la base de datos, una caída de Postgres reiniciaría todos los pods a la vez sin arreglar nada. |
| `readinessProbe` | `/actuator/health/readiness` | cada 10 s, 3 fallos | El Service deja de mandarle tráfico, el rollout no avanza y el HPA no cuenta su CPU. |

La readiness de cada servicio mira solo las dependencias que usa, igual que en compose (`MANAGEMENT_ENDPOINT_HEALTH_GROUP_READINESS_INCLUDE` en su ConfigMap):

| Servicio | Grupo readiness |
|---|---|
| auth-service | `readinessState,db,ldap` |
| identity-service | `readinessState,db` |
| promotion-service | `readinessState,db,neo4j,redis` |
| form-service | `readinessState,db` |
| gateway-service | `readinessState,redis` |

## 2. Autoscaling

| Servicio | Mín. | Máx. | Métrica | Motivo |
|---|---|---|---|---|
| gateway-service | 1 | 2 | CPU 150 % de lo pedido (150m) | Valida el QR en cada ingreso al campus |
| auth-service | 1 | 2 | CPU 150 % | Login y emisión del QR |
| promotion-service | 1 | 2 | CPU 150 % | Estado de salud que consulta el resto |

Decisiones:

- **150 % de 100m**: el uso se mide contra `requests` (100m) y el límite es 500m. 150m indica una JVM ocupada que todavía no está estrangulada.
- **Sin métrica de memoria**: el heap de la JVM no baja al terminar la carga, así que el HPA nunca volvería a bajar.
- **`behavior`**: sube como mucho un pod por minuto y espera 5 minutos sin carga antes de bajar, para no arrancar y matar JVMs por un pico corto.
- **Sin `spec.replicas` en los Deployments**: si lo tuvieran, cada `kubectl apply` del pipeline (US-39) devolvería el servicio a una réplica en plena carga. `validate.sh` lo exige para todo Deployment con HPA.

## 3. Cuota

La `ResourceQuota` de US-21 permite 1800m de CPU y 6Gi de memoria pedidos por namespace. El peor caso, con cada HPA en su máximo:

| Ambiente | Middleware | 5 servicios | 3 réplicas extra | Total | Cuota |
|---|---|---|---|---|---|
| dev | 500m / 1920Mi | 500m / 1920Mi | 300m / 1152Mi | 1300m / 4992Mi | 1800m / 6144Mi |
| stage y prod | 800m / 2880Mi | 500m / 1920Mi | 300m / 1152Mi | 1600m / 5952Mi | 1800m / 6144Mi |

`validate.sh` hace esta suma en cada overlay y falla si no cabe. Cuando lleguen dashboard, file y notification (el resto de US-37), stage y prod se pasan de la cuota en memoria: habrá que subirla en `components/prod-sizing` (el nodo tiene 8 GiB) o bajar los `requests` de los servicios.

La estrategia de despliegue sigue en `maxSurge: 0` (US-37): un rollout no crea pods extra, así que no compite con el HPA por la cuota.

## 4. Validación

```bash
bash deploy/k8s/scripts/validate.sh
```

Además de lo de US-21 y US-37, comprueba en cada overlay:

- que cada Deployment tiene las tres sondas con los endpoints de Actuator;
- que cada HPA apunta a un Deployment del overlay, con `minReplicas >= 1` y `maxReplicas >= minReplicas`;
- que los Deployments con HPA no fijan `spec.replicas`;
- que el peor caso de la tabla anterior cabe en la cuota.

Pendiente en el clúster: con dev desplegado, `kubectl -n circleguard-dev get hpa` debe mostrar la CPU actual (no `<unknown>`), y la prueba de Locust (US-27) sirve para ver al gateway subir a dos réplicas.
