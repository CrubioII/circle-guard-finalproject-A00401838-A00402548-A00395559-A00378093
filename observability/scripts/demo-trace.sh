#!/usr/bin/env bash
# Genera una traza verificable form -> Kafka -> promotion -> notification y la busca en Jaeger
# (US-25 / SCRUM-94, CA3). Requiere form (8086), promotion y notification corriendo con Kafka,
# Neo4j y Jaeger arriba. Ver docs/operaciones/TRAZADO_DISTRIBUIDO_US25.md.
#
#   NEO4J_CONTAINER=circleguard-neo4j NEO4J_PASSWORD=<clave> bash observability/scripts/demo-trace.sh
set -euo pipefail

FORM_URL="${FORM_URL:-http://localhost:8086}"
JAEGER_URL="${JAEGER_URL:-http://localhost:16686}"
NEO4J_CONTAINER="${NEO4J_CONTAINER:-circleguard-neo4j}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASSWORD="${NEO4J_PASSWORD:-password}"

user_id=$(uuidgen | tr 'A-Z' 'a-z')
contact_id=$(uuidgen | tr 'A-Z' 'a-z')
now_ms=$(( $(date +%s) * 1000 ))

echo "1) Usuario de prueba $user_id con un contacto reciente en Neo4j"
# promotion-service solo publica promotion.status.changed si el usuario tiene al menos un contacto.
docker exec "$NEO4J_CONTAINER" cypher-shell -u "$NEO4J_USER" -p "$NEO4J_PASSWORD" \
  "MERGE (a:User {anonymousId:'$user_id'}) SET a.status='ACTIVE'
   MERGE (b:User {anonymousId:'$contact_id'}) SET b.status='ACTIVE'
   MERGE (a)-[r:ENCOUNTERED]->(b) SET r.startTime=$now_ms, r.isValid=true" >/dev/null

echo "2) Cuestionario activo con una pregunta de síntomas"
questionnaire=$(curl -sf -X POST "$FORM_URL/api/v1/questionnaires" -H 'Content-Type: application/json' \
  -d '{"title":"Demo US-25","description":"traza","questions":[{"text":"Do you have fever?","type":"YES_NO","orderIndex":0}]}')
questionnaire_id=$(echo "$questionnaire" | sed -E 's/^\{"id":"([^"]+)".*/\1/')
question_id=$(echo "$questionnaire" | sed -E 's/.*"questions":\[\{"id":"([^"]+)".*/\1/')
curl -sf -X POST "$FORM_URL/api/v1/questionnaires/$questionnaire_id/activate" >/dev/null

echo "3) Encuesta con síntomas (inicia la traza)"
curl -sf -X POST "$FORM_URL/api/v1/surveys" -H 'Content-Type: application/json' \
  -d "{\"anonymousId\":\"$user_id\",\"responses\":{\"$question_id\":\"YES\"}}" >/dev/null

echo "4) Esperando a que los spans lleguen a Jaeger..."
sleep 10
trace_id=$(curl -sf "$JAEGER_URL/api/traces?service=circleguard-notification-service&operation=promotion.status.changed%20receive&lookback=5m&limit=1" \
  | grep -oE '"traceID":"[0-9a-f]+"' | head -1 | cut -d'"' -f4)
if [ -z "$trace_id" ]; then
  echo "No se encontró la traza en Jaeger" >&2
  exit 1
fi
services=$(curl -sf "$JAEGER_URL/api/traces/$trace_id" | grep -oE '"serviceName":"circleguard-[a-z]+-service"' | sort -u | cut -d'"' -f4)
echo "Traza $trace_id con los servicios:"
echo "$services" | sed 's/^/  - /'
for s in form promotion notification; do
  echo "$services" | grep -q "circleguard-$s-service" || { echo "Falta $s en la traza" >&2; exit 1; }
done
echo "Abre $JAEGER_URL/trace/$trace_id"
