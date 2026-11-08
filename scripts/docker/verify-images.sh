#!/usr/bin/env bash
# =============================================================================
# CircleGuard - Verify the 8 backend images (US-06, subtask 3)
#
# For every image it checks:
#   1. Image exists and reports its size.
#   2. Runtime user is NOT root (configured USER + `whoami` / `id -u` inside the container).
#   3. EXPOSE matches the expected service port and a HEALTHCHECK is defined.
#   4. (unless SKIP_STARTUP=1) The container boots and Docker reports it "healthy"
#      (Actuator /actuator/health/liveness).
#
# Startup needs the middleware from docker-compose.dev.yml (PostgreSQL, Neo4j, Kafka, Redis, LDAP):
#   docker compose -f docker-compose.dev.yml up -d
# The script attaches each container to the same Docker network as `circleguard-postgres`
# (override with NETWORK=<name>) and points Spring to the compose service hostnames.
#
# Usage:
#   scripts/docker/verify-images.sh [service-short-name ...]
#   SKIP_STARTUP=1 scripts/docker/verify-images.sh
# =============================================================================
set -uo pipefail

REGISTRY="${REGISTRY:-circleguard}"
TAG="${TAG:-1.0.0-SNAPSHOT}"
SKIP_STARTUP="${SKIP_STARTUP:-0}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"

# service -> "port database"
declare -A SPEC=(
  [auth-service]="8180 circleguard_auth"
  [identity-service]="8083 circleguard_identity"
  [promotion-service]="8088 circleguard_promotion"
  [form-service]="8086 circleguard_form"
  [gateway-service]="8087 -"
  [notification-service]="8082 -"
  [file-service]="8085 -"
  [dashboard-service]="8084 circleguard_dashboard"
)
ORDER=(auth-service identity-service promotion-service form-service gateway-service
       notification-service file-service dashboard-service)
SERVICES=("${@:-${ORDER[@]}}")

if [[ "${SKIP_STARTUP}" != "1" ]]; then
  NETWORK="${NETWORK:-$(docker inspect circleguard-postgres \
    --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)}"
  if [[ -z "${NETWORK}" ]]; then
    echo "ERROR: middleware not running. Start it with: docker compose -f docker-compose.dev.yml up -d" >&2
    echo "       (or run with SKIP_STARTUP=1 to only run the static checks)" >&2
    exit 2
  fi
fi

failures=0
report=()
fail() { echo "   FAIL: $*"; failures=$((failures + 1)); status="FAIL"; }

for svc in "${SERVICES[@]}"; do
  read -r port db <<<"${SPEC[$svc]:-}"
  image="${REGISTRY}/${svc}:${TAG}"
  status="OK"
  echo "==> ${image}"

  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    fail "image not found (run scripts/docker/build-images.sh ${svc})"
    report+=("${svc}|-|-|-|-|${status}")
    continue
  fi

  size="$(docker image ls "${image}" --format '{{.Size}}' | head -n1)"
  cfg_user="$(docker image inspect "${image}" --format '{{.Config.User}}')"
  exposed="$(docker image inspect "${image}" --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}')"
  hc="$(docker image inspect "${image}" --format '{{if .Config.Healthcheck}}{{join .Config.Healthcheck.Test " "}}{{end}}')"
  whoami_out="$(docker run --rm --entrypoint sh "${image}" -c 'echo "$(whoami) $(id -u)"' 2>/dev/null)"
  run_user="${whoami_out% *}"
  run_uid="${whoami_out##* }"

  echo "   size=${size} USER=${cfg_user} whoami=${run_user} uid=${run_uid} expose=${exposed}"
  [[ -z "${cfg_user}" || "${cfg_user}" == "root" || "${cfg_user%%:*}" == "0" ]] && fail "image USER is root/unset"
  [[ "${run_user}" == "root" || "${run_uid}" == "0" || -z "${run_uid}" ]] && fail "container runs as root"
  [[ "${exposed}" != *"${port}/tcp"* ]] && fail "EXPOSE ${port} missing"
  [[ -z "${hc}" ]] && fail "HEALTHCHECK missing"

  health="skipped"
  if [[ "${SKIP_STARTUP}" != "1" ]]; then
    name="verify-${svc}"
    docker rm -f "${name}" >/dev/null 2>&1
    env_args=(
      -e SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka:9092
      -e SPRING_DATA_REDIS_HOST=redis
      -e SPRING_NEO4J_URI=bolt://neo4j:7687
      -e SPRING_LDAP_URLS=ldap://openldap:389
      -e AUTH_API_URL=http://verify-auth-service:8180
    )
    [[ "${db}" != "-" ]] && env_args+=(-e "SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/${db}")
    docker run -d --name "${name}" --network "${NETWORK}" --memory 768m "${env_args[@]}" "${image}" >/dev/null

    health="starting"
    for ((t = 0; t < STARTUP_TIMEOUT; t += 5)); do
      health="$(docker inspect "${name}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null)"
      [[ "${health}" == "healthy" || "${health}" == "unhealthy" || "${health}" == "exited" ]] && break
      sleep 5
    done
    echo "   health=${health} (after ~${t}s)"
    if [[ "${health}" != "healthy" ]]; then
      fail "container did not become healthy; last log lines:"
      docker logs --tail 30 "${name}" 2>&1 | sed 's/^/      /'
    fi
    docker rm -f "${name}" >/dev/null 2>&1
  fi

  report+=("${svc}|${size}|${run_user}(${run_uid})|${exposed% }|${health}|${status}")
done

echo
printf '%-22s %-9s %-20s %-10s %-9s %s\n' SERVICE SIZE USER EXPOSE HEALTH RESULT
for row in "${report[@]}"; do
  IFS='|' read -r a b c d e f <<<"${row}"
  printf '%-22s %-9s %-20s %-10s %-9s %s\n' "$a" "$b" "$c" "$d" "$e" "$f"
done

[[ ${failures} -eq 0 ]] && echo "All checks passed." || echo "${failures} check(s) failed."
exit $(( failures > 0 ))
