# Informe de la Parte 1 (PDF)

| Archivo | Qué es |
|---|---|
| [`Informe_Parte1_CircleGuard.pdf`](Informe_Parte1_CircleGuard.pdf) | Informe compilado para entregar en la plataforma |
| [`INFORME_PARTE1.md`](INFORME_PARTE1.md) | El mismo informe en Markdown, para leerlo directamente en GitHub. Se genera desde el HTML |
| [`informe-parte1.html`](informe-parte1.html) | Fuente editable del informe: enlaces, URLs, estado y evidencia por entregable (E1.1 a E1.8), brechas y anexos |
| [`capturas/`](capturas/) | Capturas que usa el informe. La lista y las instrucciones están en [`capturas/README.md`](capturas/README.md) |
| [`scripts/capture-evidence.mjs`](scripts/capture-evidence.mjs) | Captura las páginas de Jenkins (con API token) y de Nexus |
| [`scripts/build-pdf.mjs`](scripts/build-pdf.mjs) | Compila el HTML a PDF tamaño carta, con encabezado y número de página |
| [`scripts/build-md.py`](scripts/build-md.py) | Convierte el HTML a `INFORME_PARTE1.md` (Python 3, sin dependencias) |

## Regenerar el informe

Requiere Node.js 20 y el Playwright del proyecto E2E:

```bash
cd e2e && npm ci && npx playwright install chromium && cd ..
JENKINS_USER=docente JENKINS_API_TOKEN=<token> node docs/informe/scripts/capture-evidence.mjs   # MAIN_BUILD=<n> opcional
# copiar las capturas manuales en docs/informe/capturas/ con el nombre de la tabla
node docs/informe/scripts/build-pdf.mjs                        # escribe Informe_Parte1_CircleGuard.pdf
python docs/informe/scripts/build-md.py                         # escribe INFORME_PARTE1.md
```

`build-pdf.mjs` lista al final las capturas que siguen pendientes. Antes de entregar, la lista debe estar vacía o cada faltante debe estar justificado en la sección «Brechas y plan de acción».

## Actualizar el contenido

La fuente es siempre `informe-parte1.html`. No edites `INFORME_PARTE1.md` a mano: regenera el PDF y el Markdown después de cada cambio.


- **Estado de un entregable:** tabla 1.2 y su sección en `informe-parte1.html`.
- **Fecha de corte:** `id="fecha-corte"` en la portada y el título del anexo A.
- **Diagramas:** el informe los toma directamente de `docs/arquitectura/diagramas/*.svg` y `docs/agil/diagramas/*.svg`. Si cambias un SVG, el PDF se actualiza al recompilar.
- **Secretos:** el informe no incluye secretos, igual que el repositorio.
