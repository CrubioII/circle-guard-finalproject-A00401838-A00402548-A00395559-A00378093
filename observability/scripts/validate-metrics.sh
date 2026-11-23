#!/usr/bin/env bash
# Validación reproducible de US-24 (SCRUM-93), sin clúster ni red:
#   CA1  cada servicio trae micrometer-registry-prometheus y expone /actuator/prometheus
#   CA3  cada servicio etiqueta sus métricas con application y environment
#   CA2  el dashboard técnico es JSON válido, usa el datasource provisionado y
#        filtra por ambiente y servicio
#   K8s  los manifiestos y overlays existen y Prometheus filtra por namespace y anotación
# Si hay promtool, kubectl o docker disponibles, además valida la config de
# Prometheus y genera los overlays.
#   bash observability/scripts/validate-metrics.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBS="${ROOT}/observability"
FAILS=0
ok()   { printf '  [OK]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${desc}"; else fail "${desc}"; fi; }

echo "== Servicios (CA1 y CA3)"
for svc_dir in "${ROOT}"/services/circleguard-*-service; do
    svc="$(basename "${svc_dir}")"
    gradle="${svc_dir}/build.gradle.kts"
    yml="${svc_dir}/src/main/resources/application.yml"
    check "${svc}: dependencia micrometer-registry-prometheus" grep -q 'io.micrometer:micrometer-registry-prometheus' "${gradle}"
    check "${svc}: expone el endpoint prometheus" grep -Eq '^\s+include: .*\bprometheus\b' "${yml}"
    check "${svc}: etiqueta application" grep -Eq '^\s+application: \$\{spring.application.name\}' "${yml}"
    check "${svc}: etiqueta environment" grep -Eq '^\s+environment: \$\{CG_ENVIRONMENT:' "${yml}"
    check "${svc}: histograma de http.server.requests (p95)" grep -Eq '^\s+http.server.requests: true' "${yml}"
done
SEC="${ROOT}/services/circleguard-identity-service/src/main/java/com/circleguard/identity/config/SecurityConfig.java"
check "identity-service: /actuator/prometheus sin autenticación" grep -q '"/actuator/prometheus"' "${SEC}"

echo "== Prometheus"
PROM="${OBS}/prometheus/prometheus.yml"
check "prometheus.yml: descubre pods de Kubernetes" grep -q 'role: pod' "${PROM}"
check "prometheus.yml: solo namespaces circleguard-<env>" grep -q 'circleguard-(dev|stage|prod)' "${PROM}"
check "prometheus.yml: respeta la anotación prometheus.io/scrape" grep -q '__meta_kubernetes_pod_annotation_prometheus_io_scrape' "${PROM}"
check "prometheus.yml: etiqueta environment desde el pod" grep -q 'target_label: environment' "${PROM}"
check "prometheus-compose.yml: recoge /actuator/prometheus" grep -q 'metrics_path: /actuator/prometheus' "${OBS}/prometheus/prometheus-compose.yml"
if command -v promtool >/dev/null 2>&1; then
    check "promtool check config (Kubernetes)" promtool check config "${PROM}"
    check "promtool check config (compose)" promtool check config "${OBS}/prometheus/prometheus-compose.yml"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    check "promtool check config (Kubernetes, en Docker)" docker run --rm -v "${OBS}/prometheus:/cfg:ro" --entrypoint promtool prom/prometheus:v2.53.4 check config /cfg/prometheus.yml
    check "promtool check config (compose, en Docker)" docker run --rm -v "${OBS}/prometheus:/cfg:ro" --entrypoint promtool prom/prometheus:v2.53.4 check config /cfg/prometheus-compose.yml
else
    echo "  [SKIP] promtool no disponible"
fi

echo "== Grafana (CA2)"
DASH="${OBS}/grafana/dashboards/circleguard-servicios-tecnico.json"
if command -v python3 >/dev/null 2>&1; then
    if python3 - "${DASH}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
names = {v["name"] for v in d["templating"]["list"]}
assert {"environment", "application"} <= names, "faltan variables de ambiente/servicio"
exprs = [t["expr"] for p in d["panels"] for t in p.get("targets", [])]
assert len(d["panels"]) >= 8, "pocos paneles"
assert all('$environment' in e and '$application' in e for e in exprs), "hay consultas sin filtro de ambiente/servicio"
assert all(p["datasource"]["uid"] == "prometheus" for p in d["panels"]), "datasource distinto al provisionado"
need = ["http_server_requests_seconds_bucket", "http_server_requests_seconds_count", "jvm_memory_used_bytes", "process_cpu_usage", "up{"]
assert all(any(n in e for e in exprs) for n in need), "faltan métricas operativas"
PY
    then ok "dashboard técnico: JSON válido, 8+ paneles, filtros de ambiente y servicio, métricas operativas"
    else fail "dashboard técnico inválido"; fi
fi
check "datasource Prometheus con uid fijo" grep -q 'uid: prometheus' "${OBS}/grafana/provisioning/datasources/prometheus.yaml"
check "contraseña de Grafana fuera del repositorio (Secret)" grep -q 'name: grafana-admin' "${OBS}/grafana.yaml"

echo "== Kubernetes"
for env in dev stage prod; do
    check "overlay ${env}: NetworkPolicy en circleguard-${env}" grep -q "value: circleguard-${env}" "${OBS}/overlays/${env}/kustomization.yaml"
done
if command -v kubectl >/dev/null 2>&1; then
    for env in dev stage prod; do
        check "kubectl kustomize overlays/${env}" kubectl kustomize "${OBS}/overlays/${env}"
    done
else
    echo "  [SKIP] kubectl no disponible"
fi

echo
if [[ ${FAILS} -eq 0 ]]; then
    echo "=== RESULTADO: OK — US-24 validada ==="
else
    echo "=== RESULTADO: ${FAILS} validaciones fallidas ==="
    exit 1
fi
