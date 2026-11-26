#!/usr/bin/env bash
# =============================================================================
# CircleGuard — Reporte de salud post-despliegue -> JUnit (US-31 / CA3)
#
# Convierte el JSON de deploy/scripts/verify-env-health.sh (reports/ci/health-<env>.json)
# en un reporte JUnit con un caso por contenedor, para que el resultado de la
# verificación quede visible en Jenkins (pestaña "Tests" vía el paso `junit`).
# Si el nodo no respondió (JSON sin "services"), genera un único caso fallido con el motivo.
# También lee el JSON de 'k8s-deploy.sh verify --report' (platform: k8s, US-22): un caso
# por Deployment o StatefulSet listo o no listo, y uno fallido por imagen con otra versión.
#
# Uso: deploy/scripts/health-report-to-junit.sh reports/ci/health-prod.json reports/ci/junit/health-prod.xml
# Requiere jq (incluido en la imagen de Jenkins); si falta usa la imagen ghcr.io/jqlang/jq:1.7.1.
# =============================================================================
set -euo pipefail

INPUT="${1:-}"; OUTPUT="${2:-}"
[[ -n "${INPUT}" && -n "${OUTPUT}" ]] || { echo "Uso: $0 <health.json> <junit.xml>" >&2; exit 2; }
[[ -s "${INPUT}" ]] || { echo "[health-junit] ERROR: no existe o está vacío ${INPUT}" >&2; exit 2; }

if command -v jq >/dev/null 2>&1; then
  jqx() { jq "$@"; }
else
  jqx() { docker run --rm -i ghcr.io/jqlang/jq:1.7.1 "$@"; }
fi

mkdir -p "$(dirname "${OUTPUT}")"
jqx -r '
  # Reporte de Kubernetes: se pasa al formato de compose antes de armar el JUnit.
  (if .platform == "k8s" then
     . as $r
     | .expectedTag = (.expectedTag // .version)
     | .status = (.status // (if .healthy == true then "PASS" else "FAIL" end))
     | .host = (.host // .namespace)
     | .services = (
         [($r.ready // [])[] | {service: ., ok: true, health: "ready", image: "", probe: "rollout status"}]
         + [($r.notReady // [])[] | {service: ., ok: false, health: "not-ready", image: "", probe: "rollout status",
                                     reason: "rollout incompleto"}]
         + [($r.wrongImages // [])[] | split("=") as $p
            | {service: ("imagen " + $p[0]), ok: false, health: "", image: ($p[1:] | join("=")), probe: "n/a",
               reason: ("la imagen no usa la versión " + ($r.version // ""))}])
   else . end)
  | (.env // "unknown") as $env
  | (.expectedTag // "") as $tag
  | ("circleguard." + $env + ".health") as $class
  | (.services // []) as $svcs
  | (if ($svcs | length) == 0
       then [{service: "verificacion-de-salud", ok: false, health: "unknown", image: "", probe: "n/a",
              reason: (.reason // "el nodo no devolvió resultados de salud")}]
       else $svcs end) as $cases
  | ($cases | map(select(.ok != true)) | length) as $failures
  | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<testsuites name=\"Healthchecks " + $env + "\" tests=\"\($cases | length)\" failures=\"\($failures)\">",
    "  <testsuite name=\"health-" + $env + " (" + ($tag | @html) + ")\" tests=\"\($cases | length)\" failures=\"\($failures)\" timestamp=\"" + ((.checkedAt // "") | @html) + "\">",
    "    <properties>",
    "      <property name=\"env\" value=\"" + ($env | @html) + "\"/>",
    "      <property name=\"expectedTag\" value=\"" + ($tag | @html) + "\"/>",
    "      <property name=\"status\" value=\"" + ((.status // "FAIL") | @html) + "\"/>",
    "      <property name=\"host\" value=\"" + ((.host // "") | @html) + "\"/>",
    "    </properties>",
    ($cases[] |
      "    <testcase classname=\"" + $class + "\" name=\"" + (.service | @html) + "\">"
      + (if .ok == true then ""
         else "<failure message=\"" + ((.reason // "no saludable") | @html) + "\">"
              + ("health=" + (.health // "") + " image=" + (.image // "") + " probe=" + (.probe // "") | @html)
              + "</failure>" end)
      + "<system-out>" + ("health=" + (.health // "") + " | image=" + (.image // "") + " | " + (.probe // "") | @html) + "</system-out>"
      + "</testcase>"),
    "  </testsuite>",
    "</testsuites>"
' <"${INPUT}" | tr -d '\r' >"${OUTPUT}"

echo "[health-junit] ${OUTPUT} generado desde ${INPUT}" >&2
