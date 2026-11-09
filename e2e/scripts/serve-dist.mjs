#!/usr/bin/env node
/**
 * Servidor estático mínimo (sin dependencias) para el export web de Expo (US-34).
 * Replica las reglas de mobile/nginx.conf que importan a las pruebas:
 *   - /healthz responde 200 (usado por Playwright para saber que el servidor está listo).
 *   - /runtime-config.js se genera con las mismas variables que
 *     mobile/docker-entrypoint.d/40-circleguard-runtime-config.sh (AUTH_BASE_URL, FORM_BASE_URL, ...).
 *   - /_expo/static/* responde 404 si no existe (try_files $uri =404).
 *   - try_files $uri $uri.html $uri/ /index.html (rutas estáticas de expo-router).
 *
 * Uso: node scripts/serve-dist.mjs --dir ../mobile/dist --port 4173
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const root = path.resolve(arg('dir', process.env.E2E_WEB_DIST || '../mobile/dist'));
const port = Number(arg('port', process.env.E2E_PORT || 4173));
const host = arg('host', '127.0.0.1');

if (!fs.existsSync(path.join(root, 'index.html'))) {
  console.error(`[serve-dist] No se encontró ${root}/index.html. Ejecuta antes: (cd mobile && npx expo export --platform web)`);
  process.exit(1);
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

const RUNTIME_DEFAULTS = {
  APP_ENV: 'e2e',
  AUTH_BASE_URL: 'http://localhost:8180',
  IDENTITY_BASE_URL: 'http://localhost:8083',
  PROMOTION_BASE_URL: 'http://localhost:8088',
  FORM_BASE_URL: 'http://localhost:8086',
  GATEWAY_BASE_URL: 'http://localhost:8087',
  FILE_BASE_URL: 'http://localhost:8085',
  NOTIFICATION_BASE_URL: 'http://localhost:8082',
  DASHBOARD_BASE_URL: 'http://localhost:8084',
};

const runtimeConfigJs = () => {
  const cfg = Object.fromEntries(
    Object.entries(RUNTIME_DEFAULTS).map(([key, fallback]) => [key, process.env[key] || fallback])
  );
  cfg.API_BASE_URL = process.env.API_BASE_URL || cfg.GATEWAY_BASE_URL;
  return `window.__CIRCLEGUARD_CONFIG__ = Object.freeze(${JSON.stringify(cfg, null, 2)});\n`;
};

const isFile = (p) => {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
};

const resolveFile = (urlPath) => {
  const clean = path.normalize(decodeURIComponent(urlPath)).replace(/^([/\\])+/, '');
  const candidate = path.join(root, clean);
  if (!candidate.startsWith(root)) return null;
  if (clean.startsWith(`_expo${path.sep}static`)) return isFile(candidate) ? candidate : undefined;
  const options = [candidate, `${candidate}.html`, path.join(candidate, 'index.html')];
  return options.find(isFile) ?? path.join(root, 'index.html');
};

const server = http.createServer((req, res) => {
  const urlPath = new URL(req.url ?? '/', 'http://localhost').pathname;
  if (urlPath === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end('{"status":"UP"}');
    return;
  }
  if (urlPath === '/runtime-config.js') {
    res.writeHead(200, { 'Content-Type': MIME['.js'], 'Cache-Control': 'no-store' });
    res.end(runtimeConfigJs());
    return;
  }
  const file = resolveFile(urlPath);
  if (file === null) {
    res.writeHead(403).end();
    return;
  }
  if (file === undefined) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});

server.listen(port, host, () => {
  console.log(`[serve-dist] Sirviendo ${root} en http://${host}:${port}`);
});
