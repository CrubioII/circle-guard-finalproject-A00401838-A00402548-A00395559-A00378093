/**
 * US-17 (SCRUM-29 / SCRUM-82) — Flujo E2E 1: inicio de sesión.
 * CA2: verifica el resultado visible (pantalla de inicio) y la respuesta funcional
 * (petición de login con las credenciales y sesión persistida).
 * CA3: corre contra cualquier ambiente configurado con BASE_URL.
 */
import { test, expect, STORAGE_KEYS, mockApiEnabled } from '../../support/fixtures';

test.describe('Inicio de sesión @us17', () => {
  test('credenciales válidas abren el inicio y guardan la sesión', async ({ page, api, session, consoleErrors }) => {
    await session.clear();
    if (mockApiEnabled) {
      await api.json('POST', '/api/v1/auth/login', { token: 'e2e-jwt', anonymousId: 'e2e-anon-login' });
      await api.json('GET', '/api/v1/auth/qr/generate', { qrToken: 'e2e-qr-token', expiresIn: '60' });
    }

    await page.goto('/login');
    await page.getByPlaceholder('Username').fill(process.env.E2E_USERNAME || 'staff_guard');
    await page.getByPlaceholder('Password').fill(process.env.E2E_PASSWORD || 'password');

    const loginRequest = page.waitForRequest(
      (req) => req.url().includes('/api/v1/auth/login') && req.method() === 'POST'
    );
    await page.getByText('SIGN IN', { exact: true }).click();

    const body = (await loginRequest).postDataJSON();
    expect(body.username).toBe(process.env.E2E_USERNAME || 'staff_guard');

    await expect(page).not.toHaveURL(/\/login$/);
    await expect(page.getByText('STATUS').filter({ visible: true })).toBeVisible();
    const storedId = await page.evaluate((k) => window.localStorage.getItem(k), STORAGE_KEYS.anonymousId);
    expect(storedId).toBeTruthy();
    expect(consoleErrors, 'errores de JavaScript no controlados').toEqual([]);
  });

  test('credenciales inválidas muestran el error y no salen del login', async ({ page, api, session }) => {
    test.skip(!mockApiEnabled, 'El rechazo se simula; contra backend real se cubre en US-33.');
    await session.clear();
    await api.json('POST', '/api/v1/auth/login', { message: 'Bad credentials' }, 401);

    // En web la app usa window.alert(): se captura y se cierra para que la página siga activa.
    const alerts: string[] = [];
    page.on('dialog', async (dialog) => {
      alerts.push(dialog.message());
      await dialog.accept();
    });

    await page.goto('/login');
    await page.getByPlaceholder('Username').fill('intruso');
    await page.getByPlaceholder('Password').fill('incorrecta');
    await page.getByText('SIGN IN', { exact: true }).click();

    await expect.poll(() => alerts.join(' | ')).toContain('401');
    // Sigue en el formulario de login y sin sesión guardada.
    await expect(page.getByPlaceholder('Username')).toBeVisible();
    await expect(page.getByText('SIGN IN', { exact: true })).toBeVisible();
    const storedToken = await page.evaluate((k) => window.localStorage.getItem(k), STORAGE_KEYS.token);
    expect(storedToken).toBeNull();
  });
});
