# CircleGuard — E2E con Playwright

| Carpeta | Contenido | Historia |
|---|---|---|
| `tests/smoke/` | Arranque del cliente web (`@smoke`) | US-34 |
| `tests/flows/` | Flujos de negocio (`@us17`); convenciones en [`tests/flows/README.md`](tests/flows/README.md) | US-17 |
| `tests/deployed/` | Contratos HTTP contra un ambiente **desplegado** (`@deployed`, proyecto `deployed-api`) | US-13 |
| `support/fixtures.ts`, `support/endpoints.ts` | Fixtures compartidos (`session`, `api`, `consoleErrors`, `runtimeConfigFromEnv`) y URLs por ambiente | US-34 / US-13 |

## Modos de ejecución

```bash
# 1) Pre-despliegue (US-34): cliente web exportado + APIs simuladas
(cd mobile && npx expo export --platform web) && cd e2e && npm ci && npx playwright install chromium && npx playwright test

# 2) Contra un ambiente desplegado (US-13): APIs reales + contratos @deployed
bash deploy/scripts/run-e2e.sh --env dev --host <ip-dev>   # túneles SSH (lo que hace Jenkins)
bash deploy/scripts/run-e2e.sh --env dev --local           # pila local de deploy/compose/smoke-up.sh (KEEP_UP=1)
```

En el modo 2 se activa el proyecto `deployed-api` (por `E2E_TARGET_ENV`), se desactivan las simulaciones (`E2E_MOCK_API=false`) y los reportes van a `reports/<env>/`. **Cualquier test fallido bloquea la promoción a stage.** Detalle completo: [`docs/arquitectura/DEPLOY_PROMOTION_US13.md`](../docs/arquitectura/DEPLOY_PROMOTION_US13.md).
