// Pruebas de .github/scripts/pr-rules.js. Ejecutar: node --test .github/scripts/pr-rules.test.js
const test = require('node:test');
const assert = require('node:assert');
const { evaluate, isCode } = require('./pr-rules');

const body = [
  '## Resumen', 'Agrega el escaneo de Trivy.',
  '## Cómo probarlo', '`bash infra/scripts/test-platform-scripts.sh`',
  '## Criterios de aceptación', '- [x] CA1',
].join('\n');
const small = [{ filename: 'infra/scripts/trivy-scan.sh', additions: 150, deletions: 0 }];

test('un PR pequeño de una historia con la plantilla llena pasa', () => {
  const r = evaluate({ title: 'feat(ci): add blocking Trivy scan for US-38', branch: 'feature/US-38-trivy', body, files: small });
  assert.deepStrictEqual(r.errors, []);
  assert.deepStrictEqual(r.summary.stories, ['US-38']);
});

test('R1: título fuera de Conventional Commits', () => {
  const r = evaluate({ title: 'Feature/us 38 trivy', branch: 'feature/US-38-trivy', body, files: small });
  assert.ok(r.errors.some((e) => e.startsWith('R1')));
});

test('R2: dos historias en un PR', () => {
  const r = evaluate({ title: 'feat(ci): add Trivy and Terraform for US-38 and US-22', branch: 'x', body, files: small });
  assert.ok(r.errors.some((e) => e.startsWith('R2') && e.includes('US-22')));
});

test('R2: sin historia solo se permite en chore, ci y build', () => {
  assert.ok(evaluate({ title: 'feat(ci): add a scanner to the pipeline', branch: 'feature/x', body, files: small }).errors.some((e) => e.startsWith('R2')));
  assert.ok(!evaluate({ title: 'chore(github): enforce pull request size rules', branch: 'chore/x', body, files: small }).errors.some((e) => e.startsWith('R2')));
});

test('R2: la historia puede venir de la rama', () => {
  const r = evaluate({ title: 'docs(patterns): catalog existing design patterns', branch: 'docs/US-23-patrones', body, files: small });
  assert.deepStrictEqual(r.summary.stories, ['US-23']);
  assert.deepStrictEqual(r.errors, []);
});

test('R3: pruebas y documentación no cuentan para el límite', () => {
  const files = [
    { filename: 'Jenkinsfile', additions: 300, deletions: 20 },
    { filename: 'jenkins/test/validatePlatformFlow.groovy', additions: 400, deletions: 0 },
    { filename: 'infra/scripts/test-platform-scripts.sh', additions: 200, deletions: 0 },
    { filename: 'docs/arquitectura/X.md', additions: 500, deletions: 0 },
  ];
  const r = evaluate({ title: 'feat(ci): run terraform in jenkins for US-22', branch: 'b', body, files });
  assert.strictEqual(r.summary.codeLines, 320);
  assert.deepStrictEqual(r.errors, []);
});

test('R3: un PR grande falla, y size-exception exige justificación', () => {
  const files = [{ filename: 'Jenkinsfile', additions: 500, deletions: 10 }];
  const title = 'feat(ci): run terraform in jenkins for US-22';
  assert.ok(evaluate({ title, branch: 'b', body, files }).errors.some((e) => e.startsWith('R3')));
  assert.ok(evaluate({ title, branch: 'b', body, files, labels: ['size-exception'] }).errors.some((e) => e.includes('Justificación')));
  const justified = body + '\n## Justificación de tamaño\nReemplazo mecánico de IP en 37 archivos.';
  assert.deepStrictEqual(evaluate({ title, branch: 'b', body: justified, files, labels: [{ name: 'size-exception' }] }).errors, []);
});

test('R4: la plantilla sin llenar falla', () => {
  const empty = '## Resumen\n<!-- qué y por qué -->\n## Cómo probarlo\n-\n## Criterios de aceptación\n';
  const r = evaluate({ title: 'feat(ci): add blocking Trivy scan for US-38', branch: 'b', body: empty, files: small });
  assert.strictEqual(r.errors.filter((e) => e.startsWith('R4')).length, 3);
});

test('clasificación de archivos de código', () => {
  assert.ok(isCode('Jenkinsfile'));
  assert.ok(isCode('infra/scripts/trivy-scan.sh'));
  assert.ok(!isCode('infra/scripts/test-rollback.sh'));
  assert.ok(!isCode('services/a/src/test/java/ATest.java'));
  assert.ok(!isCode('infra/terraform/envs/dev/tests/plan.tftest.hcl'));
  assert.ok(!isCode('README.md'));
});
