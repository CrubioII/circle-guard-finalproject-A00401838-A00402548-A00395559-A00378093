#!/usr/bin/env bash
# Demo de US-41 (SCRUM-122): genera tráfico de negocio y verifica una alerta crítica de extremo a extremo.
#   1. Crea usuarios con un contacto en Neo4j y les reporta estados (promociones + tiempo de contención).
#   2. Valida QR en el gateway (check-ins permitidos e inválidos).
#   3. Detiene gateway-service y espera el correo de CircleGuardServicioCaido en Mailpit;
#      lo vuelve a levantar y espera el correo RESOLVED.
# Requiere el ambiente dev en compose y observability/docker-compose.observability.yml arriba.
# Ver docs/operaciones/DASHBOARDS_ALERTAS_US41.md.
set -euo pipefail

PROMOTION_URL="${PROMOTION_URL:-http://localhost:8088}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8087}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"
MAILPIT_URL="${MAILPIT_URL:-http://localhost:8025}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-circleguard-dev}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
: "${NEO4J_PASSWORD:?NEO4J_PASSWORD es obligatorio}" "${JWT_SECRET:?JWT_SECRET es obligatorio}" "${QR_SECRET:?QR_SECRET es obligatorio}"
USERS="${USERS:-8}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() { # jwt <secreto> <payload-json>
  local head body sig
  head=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  body=$(printf '%s' "$2" | b64url)
  sig=$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -hmac "$1" -binary | b64url)
  printf '%s.%s.%s' "$head" "$body" "$sig"
}
container() { docker ps -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --filter "label=com.docker.compose.service=$1"; }
mails() { # mails <asunto>: cuántos correos de Mailpit tienen ese asunto
  curl -sfG "$MAILPIT_URL/api/v1/search" --data-urlencode "query=subject:\"$1\"" | grep -oE '"messages_count":[0-9]+' | cut -d: -f2
}
wait_mail() { # wait_mail <asunto> <cantidad previa>
  for _ in $(seq 1 40); do
    [ "$(mails "$1")" -gt "$2" ] && return 0
    sleep 10
  done
  echo "No llegó el correo \"$1\"" >&2; exit 1
}

health_token=$(jwt "$JWT_SECRET" '{"sub":"demo-us41","permissions":["ROLE_HEALTH_CENTER"]}')
neo4j=$(container neo4j)

echo "1) $USERS promociones con contactos reales en Neo4j"
for i in $(seq 1 "$USERS"); do
  user=$(uuidgen | tr 'A-Z' 'a-z'); contact=$(uuidgen | tr 'A-Z' 'a-z')
  docker exec "$neo4j" cypher-shell -u "$NEO4J_USER" -p "$NEO4J_PASSWORD" \
    "MERGE (a:User {anonymousId:'$user'}) SET a.status='ACTIVE'
     MERGE (b:User {anonymousId:'$contact'}) SET b.status='ACTIVE'
     MERGE (a)-[r:ENCOUNTERED]->(b) SET r.startTime=timestamp(), r.isValid=true" >/dev/null
  status=$([ $((i % 2)) -eq 0 ] && echo CONFIRMED || echo SUSPECT)
  curl -sf -X POST "$PROMOTION_URL/api/v1/health/report" -H "Authorization: Bearer $health_token" \
    -H 'Content-Type: application/json' -d "{\"anonymousId\":\"$user\",\"status\":\"$status\"}"
  curl -sf -X POST "$GATEWAY_URL/api/v1/gate/validate" -H 'Content-Type: application/json' \
    -d "{\"token\":\"$(jwt "$QR_SECRET" "{\"sub\":\"$contact\"}")\"}" >/dev/null
done

echo "2) Check-ins con QR inválido"
for _ in 1 2 3; do
  curl -sf -X POST "$GATEWAY_URL/api/v1/gate/validate" -H 'Content-Type: application/json' -d '{"token":"qr-falso"}' >/dev/null
done
curl -sf "$GATEWAY_URL/actuator/prometheus" | grep '^circleguard_checkins_total'
curl -sf "$PROMOTION_URL/actuator/prometheus" | grep -E '^circleguard_(promotions_total|containment_seconds_count)'

firing="[FIRING] CircleGuardServicioCaido circleguard-gateway-service"
resolved="[RESOLVED] CircleGuardServicioCaido circleguard-gateway-service"
firing_before=$(mails "$firing"); resolved_before=$(mails "$resolved")

echo "3) Se detiene gateway-service para disparar CircleGuardServicioCaido (tarda ~2 min)"
docker stop "$(container gateway-service)" >/dev/null
wait_mail "$firing" "$firing_before"
curl -sf "$ALERTMANAGER_URL/api/v2/alerts?filter=alertname%3D%22CircleGuardServicioCaido%22" | grep -o '"state":"[a-z]*"' | head -1
echo "   Correo FIRING recibido en $MAILPIT_URL"

echo "4) Se levanta gateway-service y se espera el correo RESOLVED"
docker start "$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --filter "label=com.docker.compose.service=gateway-service")" >/dev/null
wait_mail "$resolved" "$resolved_before"
echo "   Correo RESOLVED recibido. Alerta verificada de extremo a extremo."
