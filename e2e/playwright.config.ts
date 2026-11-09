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
 *
 * US-13 — E2E contra un ambiente DESPLEGADO (compuerta de promoción dev -> stage):
 *   - deploy/scripts/run-e2e.sh define E2E_TARGET_ENV, BASE_URL (cliente web de dev) y
 *     E2E_MOCK_API=false: los flujos @us17 corren contra los servicios reales.
 *   - Con E2E_TARGET_ENV se habilita además el proyecto `deployed-api` (tests/deployed/,
 *     @deployed): contratos HTTP de salud, login/identity y QR -> gateway sin navegador.
 *   - E2E_REPORT_DIR separa los reportes de esa corrida (p. ej. reports/dev).
 */
import { defineConfig, devices } from '@playwright/test';
import * as path from 'path';

const isCI = !!process.env.CI;
const externalBaseUrl = process.env.BASE_URL?.trim();
const localPort = Number(process.env.E2E_PORT || 4173);
const baseURL = (externalBaseUrl || `http://127.0.0.1:${localPort}`).replace(/\/+$/, '');
const distDir = process.env.E2E_WEB_DIST || path.resolve(__dirname, '../mobile/dist');
const headless = !(process.env.HEADED === '1' && !isCI);
// US-13: solo contra un ambiente desplegado existen los contratos de API de tests/deployed/.
const deployedTarget = process.env.E2E_TARGET_ENV?.trim();
const reportDir = process.env.E2E_REPORT_DIR?.trim() || 'reports';

export default defineConfig({
  testDir: './tests',
  outputDir: deployedTarget ? `./test-results/${deployedTarget}` : './test-results',
  fullyParallel: true,
  forbidOnly: isCI,
  // CA3: sin reintentos por defecto para que un flujo inestable también rompa el pipeline.
  retries: Number(process.env.E2E_RETRIES || 0),
  workers: isCI ? 2 : undefined,
  timeout: 30_000,
  expect: { timeout: 10_000 },

  reporter: [
    ['list'],
    ['html', { outputFolder: `${reportDir}/html`, open: 'never' }],
    ['junit', { outputFile: `${reportDir}/junit/results.xml`, embedAnnotationsAsProperties: true }],
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
      testIgnore: '**/deployed/**',
      use: { ...devices['Desktop Chrome'] },
    },
    // US-13: contratos HTTP contra el ambiente desplegado (sin navegador; usan el fixture `request`).
    ...(deployedTarget
      ? [{ name: 'deployed-api', testMatch: '**/deployed/**/*.spec.ts', use: { extraHTTPHeaders: { Accept: 'application/json' } } }]
      : []),
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
