// =============================================================================
// CircleGuard — Compila el informe de la Parte 1 a PDF (US-19 / CA4)
//
// Fuente: docs/informe/informe-parte1.html (+ capturas/ y los diagramas SVG de docs/).
// Salida: docs/informe/Informe_Parte1_CircleGuard.pdf
//
// Uso (desde la raíz del repo; reutiliza el Playwright instalado en e2e/):
//   cd e2e && npm ci && npx playwright install chromium && cd ..
//   node docs/informe/scripts/build-pdf.mjs
// =============================================================================
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../../..');
const require = createRequire(join(root, 'e2e', 'package.json'));
const { chromium } = require('@playwright/test');

const source = join(root, 'docs', 'informe', 'informe-parte1.html');
const output = join(root, 'docs', 'informe', 'Informe_Parte1_CircleGuard.pdf');

const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(pathToFileURL(source).href, { waitUntil: 'load' });
await page.waitForSelector('body[data-ready="true"]', { timeout: 30000 });

const pending = await page.$$eval('.pending', (els) => els.map((e) => e.querySelector('b')?.textContent));
await page.pdf({
  path: output,
  format: 'Letter',
  printBackground: true,
  displayHeaderFooter: true,
  margin: { top: '18mm', bottom: '18mm', left: '14mm', right: '14mm' },
  headerTemplate: '<div style="font-size:7px;color:#6B7280;width:100%;padding:0 14mm;font-family:Helvetica,Arial">Universidad Icesi · Ingeniería de Software V · Proyecto Final CircleGuard · Parte 1 · Equipo SuperPoderosos</div>',
  footerTemplate: '<div style="font-size:7px;color:#6B7280;width:100%;padding:0 14mm;text-align:right;font-family:Helvetica,Arial">Pág. <span class="pageNumber"></span> de <span class="totalPages"></span></div>',
});
await browser.close();

console.log(`PDF generado: ${output}`);
if (pending.length) {
  console.log(`Capturas pendientes (${pending.length}); ver docs/informe/capturas/README.md:`);
  pending.forEach((p) => console.log(`  - ${p.replace('Captura pendiente: ', '')}`));
}
