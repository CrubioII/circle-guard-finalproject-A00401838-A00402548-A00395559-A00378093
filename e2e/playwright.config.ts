import { defineConfig } from '@playwright/test';
import path from 'node:path';

// =============================================================================
// CircleGuard — Configuración E2E (US-13 / contrato para US-17)
//
// Los flujos se ejecutan contra un ambiente YA desplegado (dev en el pipeline).
// Las URLs de cada servicio llegan por variables E2E_*_URL (ver tests/support/env.ts);
// el pipeline las apunta a túneles SSH hacia el nodo de dev.
//
// Salida: JUnit en ${E2E_REPORT_DIR:-../reports/e2e}/junit.xml (lo publica Jenkins).
// Un solo test fallido => exit != 0 => la promoción a stage se bloquea.
// =============================================================================
const reportDir = process.env.E2E_REPORT_DIR ?? path.resolve(__dirname, '..', 'reports', 'e2e');

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  // Un reintento en CI absorbe fallos de red puntuales; una regresión real falla igual en ambos intentos.
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  timeout: 30_000,
  expect: { timeout: 10_000 },
  reporter: [
    ['list'],
    ['junit', { outputFile: path.join(reportDir, 'junit.xml') }],
    ['json', { outputFile: path.join(reportDir, 'results.json') }],
  ],
  outputDir: path.join(reportDir, 'artifacts'),
  use: {
    extraHTTPHeaders: { Accept: 'application/json' },
    ignoreHTTPSErrors: true,
  },
});
