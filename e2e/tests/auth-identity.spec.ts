import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { endpoints, seededUser } from './support/env';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Flujo 2 — Login dual-chain (LDAP -> local) que anonimiza la identidad vía identity-service
// y emite un JWT; y contrato de la bóveda de identidades (mapeo determinista real -> anónimo).
test.describe('Autenticación y anonimización', () => {
  test('login de usuario sembrado devuelve JWT Bearer y anonymousId', async ({ request }) => {
    const response = await request.post(`${endpoints.auth}/api/v1/auth/login`, {
      data: { username: seededUser.username, password: seededUser.password },
    });
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body.type).toBe('Bearer');
    expect(body.token.split('.')).toHaveLength(3);
    expect(body.anonymousId).toMatch(UUID_RE);
  });

  test('login con contraseña incorrecta es rechazado con 401', async ({ request }) => {
    const response = await request.post(`${endpoints.auth}/api/v1/auth/login`, {
      data: { username: seededUser.username, password: `wrong-${randomUUID()}` },
    });
    expect(response.status()).toBe(401);
  });

  test('el anonymousId del login coincide con el mapeo de identity-service', async ({ request }) => {
    const login = await request.post(`${endpoints.auth}/api/v1/auth/login`, {
      data: { username: seededUser.username, password: seededUser.password },
    });
    expect(login.status()).toBe(200);
    const { anonymousId } = await login.json();

    const mapping = await request.post(`${endpoints.identity}/api/v1/identities/map`, {
      data: { realIdentity: seededUser.username },
    });
    expect(mapping.status()).toBe(200);
    expect((await mapping.json()).anonymousId).toBe(anonymousId);
  });

  test('identity-service mapea de forma determinista y no colisiona identidades', async ({ request }) => {
    const identity = `e2e-${randomUUID()}@circleguard.edu`;
    const first = await request.post(`${endpoints.identity}/api/v1/identities/map`, { data: { realIdentity: identity } });
    const second = await request.post(`${endpoints.identity}/api/v1/identities/map`, { data: { realIdentity: identity } });
    const other = await request.post(`${endpoints.identity}/api/v1/identities/map`, {
      data: { realIdentity: `e2e-${randomUUID()}@circleguard.edu` },
    });

    for (const response of [first, second, other]) {
      expect(response.status()).toBe(200);
    }
    const [a, b, c] = await Promise.all([first.json(), second.json(), other.json()]);
    expect(a.anonymousId).toMatch(UUID_RE);
    expect(b.anonymousId).toBe(a.anonymousId);
    expect(c.anonymousId).not.toBe(a.anonymousId);
  });
});
