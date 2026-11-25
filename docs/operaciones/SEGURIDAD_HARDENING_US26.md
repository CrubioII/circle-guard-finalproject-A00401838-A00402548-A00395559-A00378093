# Hardening de seguridad (`US-26`)

> **Proyecto:** CircleGuard — Ingeniería de Software V (Universidad Icesi)
> **Entregable:** `E2.6` — gestión segura de secretos, RBAC en Kubernetes y Jenkins, y TLS en los servicios expuestos.

La historia en Jira (SCRUM-95) no trae criterios de aceptación. Se trabajó con estos:

| Criterio | Qué se pide | Dónde |
|---|---|---|
| CA1 Secretos | Ningún secreto en Git ni en ConfigMaps; los Secrets se crean fuera del repo, cifrados en reposo, y se revisa el código en busca de credenciales | §4 |
| CA2 RBAC en Kubernetes | Una cuenta por microservicio sin token, y Jenkins con una cuenta limitada a su namespace en lugar del administrador del clúster | §2 (este PR) |
| CA3 RBAC en Jenkins | Roles por matriz (administrador, equipo, solo lectura) y aprobación de prod restringida | §3 |
| CA4 TLS | El Ingress sirve HTTPS y redirige HTTP a HTTPS | Siguiente PR |

## 1. Punto de partida

- **Secretos.** `create-secrets.sh` (US-21, US-37) ya crea `circleguard-middleware` y `circleguard-app` desde el `.env` del inyector, y k3s arranca con `--secrets-encryption` (US-20), así que se guardan cifrados en etcd.
- **Pods.** Ya corrían sin token montado (`automountServiceAccountToken: false`), pero todos con la cuenta `default`.
- **Jenkins → clúster.** La credencial `kubeconfig-<env>` era el kubeconfig de administrador de k3s. Un build de dev podía tocar stage, prod o `kube-system`, y leer todos los Secrets.

## 2. RBAC en Kubernetes (CA2)

```text
deploy/k8s/base/rbac/
├── kustomization.yaml
├── service-accounts.yaml   default + una ServiceAccount por microservicio, todas sin token
└── jenkins-deployer.yaml   ServiceAccount + Role + RoleBinding del namespace
deploy/k8s/scripts/create-deployer-kubeconfig.sh
```

**Microservicios.** Cada `Deployment` usa una cuenta con su mismo nombre (`auth-service`, ..., `web-client`). Ninguno llama a la API de Kubernetes, así que no tienen `Role` y no montan token. La cuenta `default` del namespace también queda sin token, para que un pod nuevo sin `serviceAccountName` no reciba credenciales. Con una identidad por servicio, los eventos de auditoría y cualquier permiso futuro quedan separados por servicio.

**Jenkins (`jenkins-deployer`).** El `Role` tiene solo lo que hace `deploy/scripts/k8s-deploy.sh`:

| Recursos | Verbos | Para qué |
|---|---|---|
| `namespaces`, `resourcequotas`, `limitranges` | get, list, watch, patch, update | `apply -k` del overlay, que incluye el propio namespace. En un `Role`, la regla sobre `namespaces` solo alcanza al namespace del `Role` |
| `configmaps`, `services`, `serviceaccounts`, `persistentvolumeclaims` | + create, delete | `apply -k` |
| `deployments`, `statefulsets` | + create, delete | `apply -k`, `rollout status`, `rollout undo` |
| `replicasets`, `controllerrevisions`, `pods`, `events` | get, list, watch | historial de rollout y diagnóstico |
| `pods/portforward` | create | túneles de `run-e2e.sh --k8s`, los E2E de la compuerta de promoción (US-39) |
| `ingresses`, `networkpolicies`, `horizontalpodautoscalers` | + create, delete | `apply -k` (el HPA es de US-38) |
| `roles`, `rolebindings` | get, list, watch, create, patch, update | el propio RBAC va en el overlay. Kubernetes no deja otorgar permisos que no se tienen, así que la cuenta no puede ampliarse |

No tiene `secrets`, `pods/exec` ni `pods/attach`, ni nada fuera de `circleguard-<env>`. El `port-forward` solo llega a pods del propio namespace, y conectarse al middleware sigue pidiendo las contraseñas que la cuenta no puede leer. Los Secrets los sigue creando un administrador con `create-secrets.sh`. `validate.sh` falla si el `Role` gana comodines, `secrets`, `pods/exec`, `pods/attach`, `escalate`, `bind` o `impersonate`, si un `Deployment` no usa su propia cuenta, si una cuenta monta token o si el overlay crea RBAC de clúster.

### 2.1 Generar la credencial de Jenkins

Lo hace un administrador con el kubeconfig de `get-kubeconfig.sh`, una vez por ambiente:

```bash
export KUBECONFIG=~/.kube/circleguard-dev.yaml
bash deploy/k8s/scripts/create-deployer-kubeconfig.sh --env dev
# Manage Jenkins → Credentials → kubeconfig-dev → reemplazar el archivo por ~/.kube/jenkins-deployer-dev.yaml
rm ~/.kube/jenkins-deployer-dev.yaml
```

El script aplica el RBAC, crea el Secret `jenkins-deployer-token` (token de la cuenta), escribe el kubeconfig con permisos `600` y, antes de entregarlo, comprueba con `kubectl auth can-i` que puede desplegar y que **no** puede leer Secrets, abrir `exec` ni tocar `kube-system` u otro ambiente. Si algo no se cumple, no deja el archivo.

**Rotación.** `--rotate` borra el Secret del token antes de crearlo de nuevo, y el token anterior deja de valer en ese momento. Después se reemplaza la credencial en Jenkins. Se rota si el archivo pudo filtrarse o cuando sale alguien del equipo.

### 2.2 Prueba en k3s local (k3d)

Clúster `k3d` con el overlay dev y los 8 microservicios (el mismo de US-37):

| Paso | Resultado |
|---|---|
| `create-deployer-kubeconfig.sh --env dev` | RBAC aplicado y las 9 comprobaciones de `can-i` correctas |
| `k8s-deploy.sh deploy --env dev --version 0.1.0` con ese kubeconfig | `apply -k` completo, sin `Forbidden` |
| `k8s-deploy.sh verify` | `Rollout completo: 15 recursos listos con la versión 0.1.0` (con el web-client de #78) |
| `k8s-deploy.sh rollback` | `rollout undo` completado |
| `kubectl port-forward svc/web-client` y `svc/auth-service` (como `run-e2e.sh --k8s`) | `200` en `/healthz` y en `/actuator/health` |
| `kubectl exec deploy/auth-service` | `Forbidden` |
| `kubectl get secrets` | `Forbidden` |
| `kubectl -n kube-system get pods` | `Forbidden` |
| Pod de `auth-service` | `serviceAccountName: auth-service`, `Running` |
| `validate.sh` (3 ambientes) | 59 recursos por ambiente, esquema válido; con `secrets` agregado al `Role`, falla como se espera |

## 3. RBAC en Jenkins (CA3)

Se cubrió en US-31 y se mantiene ([`JENKINS_SEGURIDAD_US31.md`](JENKINS_SEGURIDAD_US31.md)): cuentas locales sin registro, matriz con `admin` como único administrador, el equipo solo lanza y cancela builds (sin `Run/Replay` ni `Job/Configure`), `docente` de solo lectura, anónimo sin permisos y aprobación de prod limitada a `CG_PROD_APPROVERS`. US-26 completa el lado del clúster: aunque alguien ejecutara código propio en un build, la credencial `kubeconfig-<env>` ya no da acceso a Secrets ni a otros ambientes.

## 4. Secretos (CA1)

| Control | Estado |
|---|---|
| Sin Secrets ni contraseñas en los manifiestos | `validate.sh`: el render no puede incluir `Secret`, las contraseñas solo salen de `circleguard-middleware` y `circleguard-app`, y se buscan patrones de credenciales en `deploy/k8s` |
| Creación fuera de Git | `create-secrets.sh` desde el `.env` 600 del inyector (US-05), por archivo temporal y nunca por argumentos |
| Cifrado en reposo | k3s con `--secrets-encryption` (US-20) |
| Acceso | Solo administradores del clúster; Jenkins ya no los lee (§2) y cada pod recibe únicamente las llaves que usa |
| Revisión de credenciales en el código | GitGuardian revisa cada PR en GitHub |
