// Reglas de tamaño y trazabilidad de los Pull Requests (docs/agil/BRANCHING_STRATEGY.md, sección 7).
//
// Un PR debe poder revisarse en una sentada:
//   R1. Título en Conventional Commits: tipo(alcance): descripción.
//   R2. Una sola historia: el título (o la rama) nombra exactamente un US-XX. Los tipos
//       chore, ci y build pueden no tener historia.
//   R3. Máximo MAX_CODE_LINES líneas cambiadas de código (sin contar pruebas, documentación
//       ni archivos generados) y MAX_FILES archivos.
//   R4. La plantilla está llena: resumen, cómo probarlo y criterios de aceptación cubiertos.
// La etiqueta `size-exception` permite pasar R3 si el cuerpo trae la sección
// "Justificación de tamaño" con texto (por ejemplo, un reemplazo mecánico en muchos archivos).

const MAX_CODE_LINES = 400;
const MAX_FILES = 25;
const TYPES = ['feat', 'fix', 'perf', 'refactor', 'build', 'ci', 'docs', 'test', 'chore', 'revert', 'style'];
const TYPES_WITHOUT_STORY = ['chore', 'ci', 'build'];
const TITLE_RE = new RegExp(`^(${TYPES.join('|')})(\\([a-z0-9-]+\\))?!?: .{10,}$`);
const STORY_RE = /US-\d+/gi;

// Archivos que no cuentan para el límite de código.
const NON_CODE = [
  /^docs\//,
  /\.md$/,
  /(^|\/)(test|tests|__tests__)\//,
  /(^|\/)src\/test\//,
  /(^|[/_-])test[^/]*\.(sh|groovy|js|ts)$/,
  /(^|\/)validate[A-Z][^/]*\.groovy$/,
  /\.tftest\.hcl$/,
  /\.test\.(js|ts)$/,
  /(^|\/)package-lock\.json$/,
  /\.(svg|png|jpg|pdf)$/,
];

function isCode(path) {
  return !NON_CODE.some((re) => re.test(path));
}

function section(body, heading) {
  const re = new RegExp(`##\\s*${heading}[^\\n]*\\n([\\s\\S]*?)(\\n##\\s|$)`, 'i');
  const match = (body || '').match(re);
  if (!match) return '';
  // Quita comentarios HTML de la plantilla y viñetas vacías.
  return match[1].replace(/<!--[\s\S]*?-->/g, '').replace(/^\s*-\s*$/gm, '').trim();
}

/**
 * pr: { title, branch, body, labels: [nombres], files: [{ filename, additions, deletions }] }
 * Devuelve { ok, errors: [], summary: {...} }
 */
function evaluate(pr) {
  const errors = [];
  const title = (pr.title || '').trim();
  const type = (title.match(/^([a-z]+)/) || [])[1] || '';
  const labels = (pr.labels || []).map((l) => (typeof l === 'string' ? l : l.name));

  if (!TITLE_RE.test(title)) {
    errors.push(`R1: el título "${title}" no sigue Conventional Commits (tipo(alcance): descripción de al menos 10 caracteres).`);
  }

  const titleStories = [...new Set((title.match(STORY_RE) || []).map((s) => s.toUpperCase()))];
  const branchStories = [...new Set(((pr.branch || '').match(STORY_RE) || []).map((s) => s.toUpperCase()))];
  const stories = titleStories.length ? titleStories : branchStories;
  if (stories.length > 1) {
    errors.push(`R2: el PR mezcla varias historias (${stories.join(', ')}). Sepáralo en un PR por historia.`);
  } else if (stories.length === 0 && !TYPES_WITHOUT_STORY.includes(type)) {
    errors.push('R2: el título o la rama debe nombrar la historia (US-XX).');
  }

  const files = pr.files || [];
  const codeFiles = files.filter((f) => isCode(f.filename));
  const codeLines = codeFiles.reduce((n, f) => n + (f.additions || 0) + (f.deletions || 0), 0);
  const totalLines = files.reduce((n, f) => n + (f.additions || 0) + (f.deletions || 0), 0);
  const exception = labels.includes('size-exception');
  const justification = section(pr.body, 'Justificación de tamaño');
  if (codeLines > MAX_CODE_LINES || files.length > MAX_FILES) {
    if (!exception) {
      errors.push(`R3: ${codeLines} líneas de código en ${files.length} archivos (máximo ${MAX_CODE_LINES} líneas y ${MAX_FILES} archivos). Divide el PR o usa la etiqueta size-exception con su justificación.`);
    } else if (!justification) {
      errors.push('R3: la etiqueta size-exception exige la sección "Justificación de tamaño" con texto.');
    }
  }

  for (const heading of ['Resumen', 'Cómo probarlo', 'Criterios de aceptación']) {
    if (!section(pr.body, heading)) {
      errors.push(`R4: falta llenar la sección "${heading}" de la plantilla.`);
    }
  }

  return {
    ok: errors.length === 0,
    errors,
    summary: { stories, files: files.length, codeLines, totalLines, exception },
  };
}

module.exports = { evaluate, isCode, MAX_CODE_LINES, MAX_FILES };
