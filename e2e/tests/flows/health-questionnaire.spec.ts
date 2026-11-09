/**
 * US-17 (SCRUM-29 / SCRUM-82) — Flujo E2E 2: envío del cuestionario de salud.
 * CA2: verifica que las respuestas marcadas llegan en el POST /api/v1/surveys
 * (antes se enviaban vacías) y que el usuario vuelve al inicio.
 */
import { test, expect, mockApiEnabled } from '../../support/fixtures';

const QUESTIONNAIRE = {
  id: 'e2e-q-1',
  title: 'Daily Health Check',
  description: 'Reporte diario de síntomas',
  questions: [
    { id: 'fever', text: 'Do you have fever?', type: 'YES_NO' },
    { id: 'contact', text: 'Close contact with a confirmed case?', type: 'YES_NO' },
  ],
};

test.describe('Cuestionario de salud @us17', () => {
  test('las respuestas del usuario se envían y vuelve al inicio', async ({ page, api, session, consoleErrors }) => {
    test.skip(!mockApiEnabled, 'Requiere un cuestionario activo conocido; contra backend real usar datos sembrados.');
    await session.signIn('e2e-anon-survey', 'e2e-jwt');
    await api.json('GET', '/api/v1/questionnaires/active', QUESTIONNAIRE);
    await api.json('GET', '/api/v1/auth/qr/generate', { qrToken: 'e2e-qr-token', expiresIn: '60' });
    let submitted: any = null;
    await api.handle('POST', '/api/v1/surveys', async (route) => {
      submitted = route.request().postDataJSON();
      await route.fulfill({
        status: 201,
        contentType: 'application/json',
        headers: { 'Access-Control-Allow-Origin': '*' },
        body: JSON.stringify({ id: 'survey-1', status: 'RECEIVED' }),
      });
    });

    await page.goto('/questionnaire');
    await expect(page.getByText('Daily Health Check')).toBeVisible();

    await page.getByText('YES', { exact: true }).first().click();
    await page.getByText('NO', { exact: true }).nth(1).click();
    await page.getByText('SUBMIT REPORT').click();

    await expect.poll(() => submitted).not.toBeNull();
    expect(submitted.anonymousId).toBe('e2e-anon-survey');
    expect(submitted.responses).toEqual({ fever: 'YES', contact: 'NO' });
    await expect(page).not.toHaveURL(/\/questionnaire$/);
    expect(consoleErrors, 'errores de JavaScript no controlados').toEqual([]);
  });
});
