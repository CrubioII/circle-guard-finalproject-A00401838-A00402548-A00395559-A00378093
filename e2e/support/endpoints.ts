// Endpoints del ambiente bajo prueba. Valores por defecto = puertos de deploy/compose/docker-compose.dev.yml
// en 127.0.0.1 (pila local o túneles SSH abiertos por deploy/scripts/run-e2e.sh).
const url = (name: string, fallback: string): string =>
  (process.env[name] ?? fallback).replace(/\/+$/, '');

export const endpoints = {
  auth: url('E2E_AUTH_URL', 'http://127.0.0.1:8180'),
  identity: url('E2E_IDENTITY_URL', 'http://127.0.0.1:8083'),
  promotion: url('E2E_PROMOTION_URL', 'http://127.0.0.1:8088'),
  form: url('E2E_FORM_URL', 'http://127.0.0.1:8086'),
  gateway: url('E2E_GATEWAY_URL', 'http://127.0.0.1:8087'),
  web: url('E2E_WEB_URL', 'http://127.0.0.1:8080'),
};

// Usuario local sembrado por la migración V2__seed_test_users.sql de auth-service (rol GATE_STAFF).
export const seededUser = {
  username: process.env.E2E_USERNAME ?? 'staff_guard',
  password: process.env.E2E_PASSWORD ?? 'password',
};

export const targetEnv = process.env.E2E_TARGET_ENV ?? 'local';
