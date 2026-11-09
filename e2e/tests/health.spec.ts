import { test, expect } from '@playwright/test';
import { endpoints } from './support/env';

// Flujo 1 — Todos los servicios núcleo responden "UP" en su grupo readiness
// (que incluye sus dependencias: db, neo4j, redis, ldap) y el cliente web está sano.
const services: Array<[string, string]> = [
  ['auth-service', endpoints.auth],
  ['identity-service', endpoints.identity],
  ['promotion-service', endpoints.promotion],
  ['form-service', endpoints.form],
  ['gateway-service', endpoints.gateway],
];

test.describe('Salud del ambiente desplegado', () => {
  for (const [name, baseUrl] of services) {
    test(`${name} está listo (readiness UP)`, async ({ request }) => {
      const response = await request.get(`${baseUrl}/actuator/health/readiness`);
      expect(response.status(), `${name} readiness HTTP`).toBe(200);
      expect((await response.json()).status).toBe('UP');
    });
  }

  test('web-client responde /healthz', async ({ request }) => {
    const response = await request.get(`${endpoints.web}/healthz`);
    expect(response.status()).toBe(200);
    expect((await response.json()).status).toBe('UP');
  });
});
