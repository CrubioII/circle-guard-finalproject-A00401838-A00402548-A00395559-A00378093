# Informes del proyecto

| Archivo | Qué es |
|---|---|
| [`INFORME_PARTE2.md`](INFORME_PARTE2.md) | Informe de la Parte 2: estado y evidencia por entregable (E2.1 a E2.9) y pendientes |
| [`COSTOS_PARTE2.md`](COSTOS_PARTE2.md) | Costos estimados a precio de lista y costo real de Cost Explorer |
| [`EXECUTIVE_SUMMARY_EN.md`](EXECUTIVE_SUMMARY_EN.md) | Resumen ejecutivo en inglés (1 página) |
| [`INFORME_PARTE1.md`](INFORME_PARTE1.md) | El informe: enlaces, URLs, estado y evidencia por entregable (E1.1 a E1.8), brechas y anexos. GitHub lo muestra con sus figuras |
| [`capturas/`](capturas/) | Capturas que usa el informe. La lista y las instrucciones están en [`capturas/README.md`](capturas/README.md) |
| [`scripts/capture-evidence.mjs`](scripts/capture-evidence.mjs) | Captura las páginas de Jenkins (con API token) y de Nexus |



## Regenerar las capturas automáticas

Requiere Node.js 20 y el Playwright del proyecto E2E:

```bash
cd e2e && npm ci && npx playwright install chromium && cd ..
JENKINS_USER=docente JENKINS_API_TOKEN=<token> node docs/informe/scripts/capture-evidence.mjs   # MAIN_BUILD=<n> opcional
```

Si se necesita un PDF para la plataforma, se exporta desde `INFORME_PARTE1.md` (por ejemplo, con la extensión *Markdown PDF* de VS Code o imprimiendo la vista de GitHub).
