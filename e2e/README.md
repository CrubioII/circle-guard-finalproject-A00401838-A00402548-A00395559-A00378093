# CircleGuard — Suite E2E

Flujos end-to-end que se ejecutan contra un ambiente **ya desplegado**. El pipeline los corre contra **dev** después de cada despliegue (US-13), y solo si pasan se promueve la versión a stage.

```bash
# contra la pila local (deploy/compose/smoke-up.sh con KEEP_UP=1)
bash deploy/scripts/run-e2e.sh --env dev --local

# directamente, con URLs propias
cd e2e && npm ci && E2E_AUTH_URL=http://host:8180 npx playwright test
```

## Contrato (para US-17)

- Los nuevos flujos van como `tests/*.spec.ts` y usan `endpoints` de `tests/support/env.ts`. No se escriben URLs fijas.
- Las variables disponibles son `E2E_{AUTH,IDENTITY,PROMOTION,FORM,GATEWAY,WEB}_URL`, `E2E_TARGET_ENV`, `E2E_USERNAME`/`E2E_PASSWORD` y `E2E_REPORT_DIR`.
- Los reportes se generan en `reports/e2e/junit.xml` y `reports/e2e/results.json`, y Jenkins los publica.
- **Cualquier test fallido bloquea la promoción a stage.** En CI hay un reintento para absorber fallos de red, pero una regresión real falla en ambos intentos.
- Los datos que crean los flujos deben ser únicos (`randomUUID()`), porque dev es un ambiente compartido y persistente.

Detalle completo: [`docs/arquitectura/DEPLOY_PROMOTION_US13.md`](../docs/arquitectura/DEPLOY_PROMOTION_US13.md).
