/**
 * Smoke E2E (US-34): valida que el harness de Playwright llega al cliente web
 * configurado en BASE_URL y que la aplicación arranca sin errores de JavaScript.
 * No reemplaza los flujos de negocio de US-17 (ver tests/flows/README.md).
 */
import { test, expect } from '../../support/fixtures';

test.describe('Cliente web CircleGuard @smoke', () => {
  test('la pantalla de inicio de sesión carga con su formulario', async ({ page, session, consoleErrors }) => {
    await session.clear();
    await page.goto('/login');

    await expect(page.getByText('Welcome Back')).toBeVisible();
    await expect(page.getByPlaceholder('Username')).toBeVisible();
    await expect(page.getByPlaceholder('Password')).toBeVisible();
    await expect(page.getByText('SIGN IN', { exact: true })).toBeVisible();
    expect(consoleErrors, 'errores de JavaScript no controlados').toEqual([]);
  });

  test('un usuario sin sesión es redirigido a /login', async ({ page, session }) => {
    await session.clear();
    await page.goto('/');

    await expect(page).toHaveURL(/\/login$/);
    await expect(page.getByPlaceholder('Username')).toBeVisible();
  });
});
