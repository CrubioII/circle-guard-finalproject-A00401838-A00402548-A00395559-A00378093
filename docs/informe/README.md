# Informe de la Parte 1 (PDF)

| Archivo | Qué es |
|---|---|
| [`Informe_Parte1_CircleGuard.pdf`](Informe_Parte1_CircleGuard.pdf) | Informe compilado para entregar en la plataforma |
| [`informe-parte1.html`](informe-parte1.html) | Fuente editable del informe: enlaces, URLs, estado y evidencia por entregable (E1.1 a E1.8), brechas y anexos |
| [`capturas/`](capturas/) | Capturas que usa el informe. La lista y las instrucciones están en [`capturas/README.md`](capturas/README.md) |
| [`scripts/capture-evidence.mjs`](scripts/capture-evidence.mjs) | Captura las páginas de Jenkins y Nexus que no requieren sesión |
| [`scripts/build-pdf.mjs`](scripts/build-pdf.mjs) | Compila el HTML a PDF tamaño carta, con encabezado y número de página |

## Regenerar el informe

Requiere Node.js 20 y el Playwright del proyecto E2E:

```bash
cd e2e && npm ci && npx playwright install chromium && cd ..
node docs/informe/scripts/capture-evidence.mjs                 # capturas automáticas (MAIN_BUILD=<n> opcional)
# copiar las capturas manuales en docs/informe/capturas/ con el nombre de la tabla
node docs/informe/scripts/build-pdf.mjs                        # escribe Informe_Parte1_CircleGuard.pdf
```

`build-pdf.mjs` lista al final las capturas que siguen pendientes. Antes de entregar, la lista debe estar vacía o cada faltante debe estar justificado en la sección «Brechas y plan de acción».

## Actualizar el contenido

- **Estado de un entregable:** tabla 1.2 y su sección en `informe-parte1.html`.
- **Fecha de corte:** `id="fecha-corte"` en la portada y el título del anexo A.
- **Diagramas:** el informe los toma directamente de `docs/arquitectura/diagramas/*.svg` y `docs/agil/diagramas/*.svg`. Si cambias un SVG, el PDF se actualiza al recompilar.
- **Secretos:** el informe no incluye secretos, igual que el repositorio.
