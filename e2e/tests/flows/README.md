# Flujos E2E de negocio (US-17)

Esta carpeta aloja los flujos de negocio que exige el entregable E1.6 y que implementa **US-17**.
El framework (configuración, fixtures, reportes y etapa de Jenkins) lo entrega **US-34**.

| Flujo | Archivo esperado | Estado |
|---|---|---|
| Inicio de sesión | `login.spec.ts` | Pendiente (US-17) |
| Cuestionario de salud | `health-questionnaire.spec.ts` | Pendiente (US-17) |
| Validación de acceso (gate) | `access-validation.spec.ts` | Pendiente (US-17) |

## Convenciones

- Importar `test` y `expect` desde `../../support/fixtures` (no desde `@playwright/test`) para
  reutilizar `session`, `api` y `consoleErrors`.
- Etiquetar cada `describe` con `@us17` en el título para que `npm run test:flows` los seleccione.
- Sin backend levantado, simular las APIs con `api.json(...)`; con `E2E_MOCK_API=false` y un
  `BASE_URL` de un ambiente desplegado, los mismos specs pueden ir contra los servicios reales
  (consultar `mockApiEnabled`).
- No usar `test.only`, `test.skip` ni `test.fixme` para "pasar" el pipeline: en CI `forbidOnly`
  está activo y cualquier fallo en estos flujos hace fallar la etapa `E2E Playwright` (CA3).

Ejemplo mínimo:

```ts
import { test, expect } from '../../support/fixtures';

test.describe('Inicio de sesión @us17', () => {
  test('credenciales válidas llevan al inicio', async ({ page, api, session }) => {
    await session.clear();
    await api.json('POST', '/api/v1/auth/login', { token: 'jwt', anonymousId: 'anon-1' });
    await page.goto('/login');
    await page.getByPlaceholder('Username').fill('estudiante');
    await page.getByPlaceholder('Password').fill('secreto');
    await page.getByText('SIGN IN', { exact: true }).click();
    await expect(page).not.toHaveURL(/\/login$/);
    await expect(page.getByText('STATUS').filter({ visible: true })).toBeVisible();
  });
});
```
