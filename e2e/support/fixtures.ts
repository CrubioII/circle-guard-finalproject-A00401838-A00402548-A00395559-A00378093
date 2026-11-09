/**
 * Fixtures compartidos de Playwright para CircleGuard (US-34).
 *
 * Los flujos de negocio (US-17) importan `test` y `expect` desde aquí para reutilizar:
 *   - `consoleErrors`: errores de JavaScript no controlados capturados durante la prueba.
 *     Se omiten los avisos de hidratación de React (#418/#423/#425) que hoy produce el export
 *     estático de Expo; con E2E_STRICT_HYDRATION=1 también se reportan.
 *   - `session`: siembra/limpia la sesión anónima que el cliente web guarda en localStorage.
 *   - `api`: simula respuestas del backend (/api/v1/**) cuando el pipeline corre sin
 *     microservicios levantados. Con E2E_MOCK_API=false las peticiones van al backend real.
 */
import { test as base, expect, type Page, type Route } from '@playwright/test';

export const STORAGE_KEYS = {
  anonymousId: 'circleguard_anon_id',
  token: 'circleguard_token',
} as const;

export const mockApiEnabled = (process.env.E2E_MOCK_API ?? 'true').toLowerCase() !== 'false';

const strictHydration = process.env.E2E_STRICT_HYDRATION === '1';
const HYDRATION_ERROR = /Minified React error #(418|423|425)\b|Hydration failed|did not match/i;

type JsonHandler = (route: Route) => Promise<void> | void;

export interface ApiMock {
  /** Responde con JSON a `method` + ruta relativa (p. ej. 'POST', '/api/v1/auth/login'). */
  json(method: string, apiPath: string, body: unknown, status?: number): Promise<void>;
  /** Registra un manejador libre para la ruta indicada. */
  handle(method: string, apiPath: string, handler: JsonHandler): Promise<void>;
}

export interface SessionHelper {
  signIn(anonymousId?: string, token?: string): Promise<void>;
  clear(): Promise<void>;
}

const routeFor = (page: Page): ApiMock => ({
  async json(method, apiPath, body, status = 200) {
    await this.handle(method, apiPath, (route) =>
      route.fulfill({
        status,
        contentType: 'application/json',
        headers: { 'Access-Control-Allow-Origin': '*' },
        body: JSON.stringify(body),
      })
    );
  },
  async handle(method, apiPath, handler) {
    await page.route(`**${apiPath}`, async (route) => {
      const request = route.request();
      if (request.method() === 'OPTIONS') {
        await route.fulfill({
          status: 204,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS',
            'Access-Control-Allow-Headers': '*',
          },
        });
        return;
      }
      if (request.method() !== method.toUpperCase()) {
        await route.fallback();
        return;
      }
      await handler(route);
    });
  },
});

export const test = base.extend<{
  consoleErrors: string[];
  session: SessionHelper;
  api: ApiMock;
}>({
  consoleErrors: async ({ page }, use) => {
    const errors: string[] = [];
    page.on('pageerror', (err) => {
      if (!strictHydration && HYDRATION_ERROR.test(err.message)) return;
      errors.push(err.message);
    });
    await use(errors);
  },

  session: async ({ page }, use) => {
    await use({
      async signIn(anonymousId = 'e2e-anon-0001', token = 'e2e-token') {
        await page.addInitScript(
          ([keys, id, tk]) => {
            window.localStorage.setItem(keys.anonymousId, id);
            window.localStorage.setItem(keys.token, tk);
          },
          [STORAGE_KEYS, anonymousId, token] as const
        );
      },
      async clear() {
        await page.addInitScript((keys) => {
          window.localStorage.removeItem(keys.anonymousId);
          window.localStorage.removeItem(keys.token);
        }, STORAGE_KEYS);
      },
    });
  },

  api: async ({ page }, use) => {
    await use(routeFor(page));
  },
});

export { expect };
