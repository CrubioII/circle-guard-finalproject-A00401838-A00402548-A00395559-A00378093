// =============================================================================
// CircleGuard — Captura automática de evidencias para el informe de la Parte 1 (US-19)
//
// Toma capturas PNG de las páginas de Jenkins y Nexus y las guarda en docs/informe/capturas/
// con el nombre que espera el informe. Jenkins exige sesión (US-31): el script usa el API token
// de una cuenta (por ejemplo, docente) y lo envía solo a Jenkins, nunca a Nexus.
// Las capturas de Jira, GitHub, AWS, SonarQube y Discord se toman a mano:
// ver docs/informe/capturas/README.md.
//
// Uso (desde la raíz del repo; reutiliza el Playwright instalado en e2e/):
//   cd e2e && npm ci && cd ..
//   read -rsp "API token de Jenkins: " JENKINS_API_TOKEN; export JENKINS_API_TOKEN
//   JENKINS_USER=docente MAIN_BUILD=18 node docs/informe/scripts/capture-evidence.mjs
//   (opcionales: JENKINS_URL=http://52.14.6.11:8080 NEXUS_URL=http://52.14.6.11:8081)
//
// El token se crea en Jenkins: <usuario> -> Security -> API Token. Nunca se escribe en el repo.
// Nunca captura páginas de credenciales ni de configuración.
// =============================================================================
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../../..');
const require = createRequire(join(root, 'e2e', 'package.json'));
const { chromium } = require('@playwright/test');

const JENKINS = (process.env.JENKINS_URL || 'http://52.14.6.11:8080').replace(/\/$/, '');
const NEXUS = (process.env.NEXUS_URL || 'http://52.14.6.11:8081').replace(/\/$/, '');
const JOB = `${JENKINS}/job/circleguard-monorepo`;
const MAIN_BUILD = process.env.MAIN_BUILD || 'lastSuccessfulBuild';
const OUT = join(root, 'docs', 'informe', 'capturas');
mkdirSync(OUT, { recursive: true });

// [archivo, URL, espera adicional en ms, texto al que desplazarse (opcional), recorte {x,y,width,height} (opcional)]
const shots = [
  ['e1-2-jenkins-dashboard.png', `${JENKINS}/`, 1500],
  ['e1-2-nexus-home.png', `${NEXUS}/`, 6000],
  ['e1-3-nexus-docker-images.png', `${NEXUS}/service/rest/repository/browse/circleguard-docker/v2/circleguard/`, 1000, null, { x: 0, y: 0, width: 640, height: 700 }],
  ['e1-3-nexus-auth-service-tags.png', `${NEXUS}/service/rest/repository/browse/circleguard-docker/v2/circleguard/auth-service/tags/`, 1000, null, { x: 0, y: 0, width: 640, height: 260 }],
  ['e1-4-jenkins-multibranch-branches.png', `${JOB}/`, 1500],
  ['e1-4-jenkins-multibranch-prs.png', `${JOB}/view/change-requests/`, 1500],
  ['e1-4-jenkins-main-job.png', `${JOB}/job/main/`, 2500],
  ['e1-4-jenkins-main-build.png', `${JOB}/job/main/${MAIN_BUILD}/`, 2500],
  ['e1-5-jenkins-main-console-semver.png', `${JOB}/job/main/${MAIN_BUILD}/consoleFull`, 4000, 'Version SemVer resultante'],
  ['e1-6-jenkins-main-tests.png', `${JOB}/job/main/${MAIN_BUILD}/testReport/`, 2000],
  ['e1-6-jenkins-main-jacoco.png', `${JOB}/job/main/${MAIN_BUILD}/jacoco/`, 2000],
  ['e1-6-jenkins-main-last-build.png', `${JOB}/job/main/lastBuild/`, 2500],
];

const JENKINS_USER = process.env.JENKINS_USER || '';
const JENKINS_API_TOKEN = process.env.JENKINS_API_TOKEN || '';
if (!JENKINS_USER || !JENKINS_API_TOKEN) {
  console.log('[WARN] Sin JENKINS_USER/JENKINS_API_TOKEN: Jenkins exige sesión y sus capturas fallarán.');
}

const browser = await chromium.launch();
const viewport = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 };
// Contextos separados: la cabecera Authorization solo viaja a Jenkins.
const basicAuth = Buffer.from(`${JENKINS_USER}:${JENKINS_API_TOKEN}`).toString('base64');
const jenkinsContext = await browser.newContext({
  ...viewport,
  ...(JENKINS_USER && JENKINS_API_TOKEN ? { extraHTTPHeaders: { Authorization: `Basic ${basicAuth}` } } : {}),
});
const otherContext = await browser.newContext(viewport);
const jenkinsPage = await jenkinsContext.newPage();
const otherPage = await otherContext.newPage();
let ok = 0;
for (const [file, url, wait, scrollToText, clip] of shots) {
  const page = url.startsWith(JENKINS) ? jenkinsPage : otherPage;
  try {
    const res = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    if (page === jenkinsPage && (res?.status() === 403 || page.url().includes('/login'))) {
      throw new Error('Jenkins pidió iniciar sesión: revisa JENKINS_USER y JENKINS_API_TOKEN');
    }
    await page.waitForTimeout(wait);
    if (scrollToText) {
      const target = page.getByText(scrollToText).first();
      if (await target.count()) await target.scrollIntoViewIfNeeded();
    }
    await page.screenshot({ path: join(OUT, file), ...(clip ? { clip } : {}) });
    console.log(`[OK]   ${file}  <- ${url} (HTTP ${res?.status() ?? '?'})`);
    ok++;
  } catch (err) {
    console.log(`[FAIL] ${file}  <- ${url}: ${err.message.split('\n')[0]}`);
  }
}
await browser.close();
console.log(`${ok}/${shots.length} capturas guardadas en ${OUT}`);
