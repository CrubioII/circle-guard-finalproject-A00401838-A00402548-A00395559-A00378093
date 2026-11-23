#!/usr/bin/env bash
# US-27 (SCRUM-96): corre Locust sin interfaz contra un ambiente desplegado.
#
#   bash performance/locust/run-load-test.sh <perfil> [ambiente]
#
# Perfiles:
#   smoke   5 usuarios, 1 min    — comprobar que el script y el ambiente responden
#   load   50 usuarios, 5 min    — carga esperada en hora pico (umbrales normales)
#   stress 200 usuarios, 5 min   — por encima de lo esperado, para encontrar el punto de quiebre
#
# Las URLs de los servicios se pasan por variables (AUTH_URL, GATEWAY_URL, FORM_URL,
# PROMOTION_URL); por defecto apuntan a 127.0.0.1 con los puertos de compose, que es
# lo que dejan los túneles SSH de deploy/scripts/run-e2e.sh.
# Los reportes (HTML y CSV) quedan en reports/locust/<ambiente>/<perfil>/.
set -euo pipefail

profile="${1:-smoke}"
env_name="${2:-${CG_ENV:-dev}}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
report_dir="${repo_root}/reports/locust/${env_name}/${profile}"

case "${profile}" in
  smoke)  users=5;   spawn_rate=1;  run_time=1m ;;
  load)   users=50;  spawn_rate=5;  run_time=5m ;;
  stress) users=200; spawn_rate=10; run_time=5m
          # En estrés se espera degradación: los umbrales solo marcan hasta dónde llega
          export P95_MS="${P95_MS:-2000}" GATE_P95_MS="${GATE_P95_MS:-1000}" MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.05}" ;;
  *) echo "Perfil desconocido: ${profile} (use smoke, load o stress)" >&2; exit 2 ;;
esac

command -v locust >/dev/null 2>&1 || {
  echo "Locust no está instalado: pip install -r ${script_dir}/requirements.txt" >&2
  exit 2
}

mkdir -p "${report_dir}"
echo "[US-27] Perfil ${profile} contra ${env_name}: ${users} usuarios, ${spawn_rate}/s, ${run_time}"

locust -f "${script_dir}/locustfile.py" \
  --headless \
  --users "${users}" \
  --spawn-rate "${spawn_rate}" \
  --run-time "${run_time}" \
  --stop-timeout 10 \
  --html "${report_dir}/report.html" \
  --csv "${report_dir}/stats" \
  --csv-full-history \
  --only-summary
