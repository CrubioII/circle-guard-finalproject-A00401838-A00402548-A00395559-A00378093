# Informe de la Parte 1

| Archivo | Qué es |
|---|---|
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
