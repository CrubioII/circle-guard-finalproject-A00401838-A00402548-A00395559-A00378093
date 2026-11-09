/**
 * Configuración de Playwright para el cliente web de CircleGuard.
 * Historia de Usuario: US-34 — Framework Playwright y ejecución E2E integrada a Jenkins.
 *
 * CA1: BASE_URL parametrizable + reportes HTML y JUnit.
 *   - BASE_URL apunta a cualquier despliegue del cliente web (dev/stage/prod o local).
 *   - Si BASE_URL no se define, Playwright levanta un servidor estático sobre el
 *     export web de Expo (mobile/dist) en http://127.0.0.1:${E2E_PORT:-4173}.
 *   - Reportes: HTML en reports/html y JUnit en reports/junit/results.xml.
 * CA2: siempre headless salvo que se pida explícitamente HEADED=1 (nunca en CI).
 * CA3: `playwright test` termina con código distinto de 0 si falla cualquier spec
 *   (incluidos los flujos @us17), lo que hace fallar la etapa de Jenkins.
 */
import { defineConfig, devices } from '@playwright/test';
import * as path from 'path';

const isCI = !!process.env.CI;
const externalBaseUrl = process.env.BASE_URL?.trim();
const localPort = Number(process.env.E2E_PORT || 4173);
const baseURL = (externalBaseUrl || `http://127.0.0.1:${localPort}`).replace(/\/+$/, '');
const distDir = process.env.E2E_WEB_DIST || path.resolve(__dirname, '../mobile/dist');
const headless = !(process.env.HEADED === '1' && !isCI);

export default defineConfig({
  testDir: './tests',
  outputDir: './test-results',
  fullyParallel: true,
  forbidOnly: isCI,
  // CA3: sin reintentos por defecto para que un flujo inestable también rompa el pipeline.
  retries: Number(process.env.E2E_RETRIES || 0),
  workers: isCI ? 2 : undefined,
  timeout: 30_000,
  expect: { timeout: 10_000 },

  reporter: [
    ['list'],
    ['html', { outputFolder: 'reports/html', open: 'never' }],
    ['junit', { outputFile: 'reports/junit/results.xml', embedAnnotationsAsProperties: true }],
  ],

  use: {
    baseURL,
    headless,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    locale: 'es-CO',
    timezoneId: 'America/Bogota',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],

  // Sin BASE_URL externo se sirve el export web de Expo para que el pipeline sea autocontenido.
  webServer: externalBaseUrl
    ? undefined
    : {
        command: `node scripts/serve-dist.mjs --dir "${distDir}" --port ${localPort}`,
        url: `${baseURL}/healthz`,
        reuseExistingServer: !isCI,
        timeout: 60_000,
        stdout: 'pipe',
        stderr: 'pipe',
      },
});
