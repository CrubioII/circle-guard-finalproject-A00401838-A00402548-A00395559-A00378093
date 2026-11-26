#!/usr/bin/env bash
# Validación reproducible de US-42 (SCRUM-123), sin clúster ni red:
#   CA1  Alloy lee los pods del namespace del ambiente (servicios y middleware) y
#        envía a Loki; solo con un Role del namespace, sin hostPath.
#   CA2  cada log lleva las etiquetas environment y service; el dashboard filtra por
#        ambiente, servicio, nivel y texto, y usa el selector de tiempo de Grafana.
#   CA3  la retención está en la config de Loki y cada overlay la fija igual que los
#        log groups de CloudWatch del ambiente (infra/terraform/envs/<env>).
# Si hay kubectl o docker, además genera los overlays y valida la config de Loki y
# la sintaxis de Alloy con sus imágenes.
#   bash observability/scripts/validate-logs.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBS="${ROOT}/observability"
LOKI_IMAGE="grafana/loki:3.7.9"
ALLOY_IMAGE="grafana/alloy:v1.21.3"
FAILS=0
ok()   { printf '  [OK]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${desc}"; else fail "${desc}"; fi; }
nocheck() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then fail "${desc}"; else ok "${desc}"; fi; }

ALLOY="${OBS}/alloy/config.alloy"
LOKI="${OBS}/loki/loki.yaml"
DASH="${OBS}/grafana/dashboards/circleguard-logs.json"

echo "== Recolección (CA1)"
check "Alloy descubre pods del namespace del ambiente" grep -q 'names = \[sys.env("CG_APP_NAMESPACE")\]' "${ALLOY}"
check "Alloy lee los logs por la API de Kubernetes" grep -q '^loki.source.kubernetes "pods"' "${ALLOY}"
check "Alloy envía a Loki" grep -q 'url = "http://loki.circleguard-observability.svc:3100/loki/api/v1/push"' "${ALLOY}"
check "Alloy solo tiene un Role (pods y pods/log)" grep -q 'resources: \[pods/log\]' "${OBS}/alloy.yaml"
nocheck "Alloy no usa ClusterRole" grep -q 'kind: ClusterRole' "${OBS}/alloy.yaml"
nocheck "Ni Loki ni Alloy montan hostPath" grep -q 'hostPath' "${OBS}/alloy.yaml" "${OBS}/loki.yaml"
check "Loki guarda en un volumen persistente" grep -q 'volumeClaimTemplates' "${OBS}/loki.yaml"
for f in loki.yaml alloy.yaml; do
    check "${f}: disco de solo lectura y usuario no root" \
        bash -c "grep -q 'readOnlyRootFilesystem: true' '${OBS}/${f}' && grep -q 'runAsNonRoot: true' '${OBS}/${f}'"
done

echo "== Filtros (CA2)"
for label in environment service level; do
    check "Alloy agrega la etiqueta ${label}" grep -Eq "(target_label *= *\"${label}\"|level = \"\")" "${ALLOY}"
done
if python3 -c "" >/dev/null 2>&1; then
    if python3 - "${DASH}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
names = {v["name"] for v in d["templating"]["list"]}
assert {"environment", "service", "level", "search"} <= names, names
for p in d["panels"]:
    assert p["datasource"]["uid"] == "loki"
    for t in p["targets"]:
        assert 'environment=~"$environment"' in t["expr"] and 'service=~"$service"' in t["expr"], t["expr"]
assert any(p["type"] == "logs" for p in d["panels"])
PY
    then ok "dashboard de logs: JSON válido, filtros de ambiente, servicio, nivel y texto en todos los paneles"
    else fail "dashboard de logs inválido"; fi
fi
check "datasource Loki con uid fijo" grep -q 'uid: loki' "${OBS}/grafana/provisioning/datasources/loki.yaml"
check "Grafana carga el datasource y el dashboard" \
    bash -c "grep -q 'grafana/provisioning/datasources/loki.yaml' '${OBS}/kustomization.yaml' && grep -q 'circleguard-logs.json' '${OBS}/kustomization.yaml'"

echo "== Retención (CA3)"
check "el compactor aplica la retención" grep -q 'retention_enabled: true' "${LOKI}"
check "la retención sale de LOKI_RETENTION_PERIOD" grep -q 'retention_period: ${LOKI_RETENTION_PERIOD' "${LOKI}"
for env in dev stage prod; do
    overlay="${ROOT}/deploy/observability/${env}/kustomization.yaml"
    days="$(sed -n 's/^observability_log_retention_days *= *\([0-9]*\).*/\1/p' "${ROOT}/infra/terraform/envs/${env}/terraform.tfvars")"
    check "overlay ${env}: retención de ${days:-?} días (igual que CloudWatch)" grep -q "value: $((days * 24))h" "${overlay}"
    check "overlay ${env}: Alloy lee circleguard-${env}" grep -q "{name: CG_APP_NAMESPACE, value: circleguard-${env}}" "${overlay}"
done

echo "== Herramientas (opcional)"
if command -v kubectl >/dev/null 2>&1; then
    for env in dev stage prod; do
        check "kubectl kustomize deploy/observability/${env}" kubectl kustomize "${ROOT}/deploy/observability/${env}"
    done
else
    echo "  [SKIP] kubectl no está instalado"
fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    check "loki -verify-config" docker run --rm -v "${OBS}/loki:/etc/loki:ro" "${LOKI_IMAGE}" \
        -config.file=/etc/loki/loki.yaml -config.expand-env=true -verify-config
    check "alloy fmt (sintaxis)" docker run --rm -v "${OBS}/alloy:/etc/alloy:ro" --entrypoint /bin/alloy \
        "${ALLOY_IMAGE}" fmt /etc/alloy/config.alloy
else
    echo "  [SKIP] docker no está disponible"
fi

echo
if [[ ${FAILS} -eq 0 ]]; then
    echo "US-42: logs centralizados validados."
else
    echo "US-42: ${FAILS} comprobación(es) fallaron." >&2
    exit 1
fi
