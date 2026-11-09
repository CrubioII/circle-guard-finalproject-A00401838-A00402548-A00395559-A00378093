import { test, expect } from '@playwright/test';
import { endpoints, targetEnv } from '../../support/endpoints';

// Flujo 4 — El cliente web servido por nginx entrega la SPA y la configuración de runtime
// generada al arrancar el contenedor (US-07), apuntando a los servicios del ambiente.
test.describe('Cliente web desplegado @deployed', () => {
  test('sirve la SPA exportada por Expo', async ({ request }) => {
    const response = await request.get(`${endpoints.web}/`, { headers: { Accept: 'text/html' } });
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/html');
    expect(await response.text()).toContain('runtime-config.js');
  });

  test('runtime-config.js expone las URLs de los servicios del ambiente', async ({ request }) => {
    const response = await request.get(`${endpoints.web}/runtime-config.js`);
    expect(response.status()).toBe(200);
    const script = await response.text();
    expect(script).toContain('window.__CIRCLEGUARD_CONFIG__');
    for (const key of ['AUTH_BASE_URL', 'IDENTITY_BASE_URL', 'PROMOTION_BASE_URL', 'FORM_BASE_URL', 'GATEWAY_BASE_URL']) {
      expect(script, key).toMatch(new RegExp(`${key}: "https?://[^"]+"`));
    }
    if (targetEnv !== 'local') {
      expect(script).toContain(`APP_ENV: "${targetEnv}"`);
    }
  });
});
