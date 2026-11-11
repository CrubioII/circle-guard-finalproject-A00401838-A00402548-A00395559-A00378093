import { test, expect, APIRequestContext } from '@playwright/test';
import { endpoints, seededUser } from '../../support/endpoints';

async function loginToken(request: APIRequestContext): Promise<string> {
  const response = await request.post(`${endpoints.auth}/api/v1/auth/login`, {
    data: { username: seededUser.username, password: seededUser.password },
  });
  expect(response.status(), 'login previo al QR').toBe(200);
  return (await response.json()).token;
}

// Flujo 3 — Ingreso al campus: auth emite un QR firmado y de corta duración; gateway-service
// valida firma + vigencia (secreto QR compartido) y consulta el estado de salud en Redis.
test.describe('Ingreso al campus con QR @deployed', () => {
  test('generar QR requiere autenticación', async ({ request }) => {
    const response = await request.get(`${endpoints.auth}/api/v1/auth/qr/generate`);
    expect([401, 403]).toContain(response.status());
  });

  test('QR emitido por auth es aceptado por gateway (GREEN)', async ({ request }) => {
    const jwt = await loginToken(request);
    const qr = await request.get(`${endpoints.auth}/api/v1/auth/qr/generate`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(qr.status()).toBe(200);
    const { qrToken } = await qr.json();
    expect(qrToken.split('.')).toHaveLength(3);

    const validation = await request.post(`${endpoints.gateway}/api/v1/gate/validate`, { data: { token: qrToken } });
    expect(validation.status()).toBe(200);
    expect(await validation.json()).toEqual({ valid: true, status: 'GREEN', message: 'Welcome to Campus' });
  });

  test('la vigencia real del QR coincide con expiresIn anunciado', async ({ request }) => {
    const jwt = await loginToken(request);
    const qr = await request.get(`${endpoints.auth}/api/v1/auth/qr/generate`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    const { qrToken, expiresIn } = await qr.json();
    const claims = JSON.parse(Buffer.from(qrToken.split('.')[1], 'base64url').toString('utf8'));
    // Regresión detectada en US-13: qr.expiration=300 (ms) emitía QR ya caducados (exp == iat).
    expect(claims.exp - claims.iat, 'segundos de vigencia del QR (exp - iat)').toBe(Number(expiresIn));
  });

  test('QR con firma alterada es rechazado por gateway (RED)', async ({ request }) => {
    const jwt = await loginToken(request);
    const qr = await request.get(`${endpoints.auth}/api/v1/auth/qr/generate`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    const { qrToken } = await qr.json();
    const [header, payload, signature] = qrToken.split('.');
    const flipped = signature.startsWith('A') ? `B${signature.slice(1)}` : `A${signature.slice(1)}`;

    const validation = await request.post(`${endpoints.gateway}/api/v1/gate/validate`, {
      data: { token: `${header}.${payload}.${flipped}` },
    });
    expect(validation.status()).toBe(200);
    const body = await validation.json();
    expect(body.valid).toBe(false);
    expect(body.status).toBe('RED');
  });
});
