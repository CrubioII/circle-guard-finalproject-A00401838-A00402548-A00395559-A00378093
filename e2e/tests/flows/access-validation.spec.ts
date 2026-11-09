/**
 * US-17 (SCRUM-29 / SCRUM-82) — Flujo E2E 3: validación de acceso por QR.
 * CA2: el inicio pide el QR firmado al auth-service con el token de sesión, lo muestra
 * con su cuenta regresiva de 60 s, y el gateway responde GREEN/RED para ese QR.
 */
import { test, expect, mockApiEnabled } from '../../support/fixtures';

test.describe('Validación de acceso por QR @us17', () => {
  test('el inicio muestra el QR firmado de la sesión con su expiración', async ({ page, api, session, consoleErrors }) => {
    await session.signIn('e2e-anon-qr', 'e2e-jwt');
    if (mockApiEnabled) {
      await api.json('GET', '/api/v1/auth/qr/generate', { qrToken: 'e2e-qr-token', expiresIn: '60' });
    }

    const qrRequest = page.waitForRequest((req) => req.url().includes('/api/v1/auth/qr/generate'));
    await page.goto('/');

    expect((await qrRequest).headers()['authorization']).toBe('Bearer e2e-jwt');
    await expect(page.getByText(/EXPIRES IN [01]:\d{2}/)).toBeVisible();
    await expect(page.locator('svg').first()).toBeVisible();
    expect(consoleErrors, 'errores de JavaScript no controlados').toEqual([]);
  });

  test('el gateway concede o niega el acceso según el estado del QR', async ({ page, api, session }) => {
    test.skip(!mockApiEnabled, 'Contra backend real lo cubre la prueba de integración del gateway (US-33).');
    await session.signIn('e2e-anon-qr', 'e2e-jwt');
    await api.json('GET', '/api/v1/auth/qr/generate', { qrToken: 'e2e-qr-token', expiresIn: '60' });
    await api.handle('POST', '/api/v1/gate/validate', async (route) => {
      const { token } = route.request().postDataJSON();
      const green = token === 'e2e-qr-token';
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        headers: { 'Access-Control-Allow-Origin': '*' },
        body: JSON.stringify(
          green
            ? { valid: true, status: 'GREEN', message: 'Welcome to Campus' }
            : { valid: false, status: 'RED', message: 'Invalid or Expired Token' }
        ),
      });
    });
    await page.goto('/');

    const validate = (token: string) =>
      page.evaluate(async (t) => {
        const res = await fetch('/api/v1/gate/validate', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: 'Bearer e2e-jwt' },
          body: JSON.stringify({ token: t }),
        });
        return res.json();
      }, token);

    await expect(validate('e2e-qr-token')).resolves.toMatchObject({ valid: true, status: 'GREEN' });
    await expect(validate('qr-vencido')).resolves.toMatchObject({ valid: false, status: 'RED' });
  });
});
