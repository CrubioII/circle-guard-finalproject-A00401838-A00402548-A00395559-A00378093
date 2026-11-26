#!/usr/bin/env bash
# =============================================================================
# Pruebas sin AWS, clúster ni Docker de los scripts de plataforma:
#   infra/terraform/scripts/tf-pipeline.sh (US-22)
#   infra/scripts/trivy-scan.sh            (US-38)
#   deploy/scripts/k8s-deploy.sh           (US-39 / US-28)
#   infra/scripts/zap-scan.sh              (US-44)
# Usa binarios simulados (terraform, trivy, kubectl, docker) que registran sus argumentos.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d -t cg-platform-test-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
die()  { echo "  [FAIL] $*" >&2; exit 1; }

mkdir -p "${WORK}/bin"
# terraform simulado: plan devuelve 2 (con cambios) y escribe el plan; show imprime JSON mínimo.
cat > "${WORK}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $*" >> "${STUB_LOG}"
for a in "$@"; do case "$a" in -out=*) : > "${a#-out=}"; echo plan > "${a#-out=}" ;; esac; done
case " $* " in
  *" plan "*) echo "Plan: 1 to add"; exit 2 ;;
  *" show -json "*) echo '{"resource_changes":[{"address":"module.storage.aws_s3_bucket.this","change":{"actions":["create"]}}]}' ;;
  *" show "*) echo "# module.storage.aws_s3_bucket.this will be created" ;;
esac
exit 0
STUB
# trivy simulado: falla (exit 1) en la tabla si TRIVY_STUB_FAIL coincide con el objetivo.
cat > "${WORK}/bin/trivy" <<'STUB'
#!/usr/bin/env bash
echo "trivy $*" >> "${STUB_LOG}"
out=""; prev=""; code=0
for a in "$@"; do [[ "$prev" == "--output" ]] && out="$a"; [[ "$prev" == "--exit-code" ]] && code="$a"; prev="$a"; done
[[ -n "$out" ]] && echo "{}" > "$out"
target="${*: -1}"
if [[ "$code" == "1" && -n "${TRIVY_STUB_FAIL:-}" && "$target" == *"${TRIVY_STUB_FAIL}"* ]]; then exit 1; fi
exit 0
STUB
chmod +x "${WORK}/bin/"*
export PATH="${WORK}/bin:${PATH}" STUB_LOG="${WORK}/calls.log"
: > "${STUB_LOG}"

echo "== tf-pipeline.sh (US-22)"
export REPORT_DIR="${WORK}/tf" TF_STATE_BUCKET="bucket-prueba"
bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" plan --env stage >/dev/null
grep -q -- "-backend-config=bucket=bucket-prueba" "${STUB_LOG}" || die "init no usa TF_STATE_BUCKET"
grep -q -- "-backend-config=key=envs/stage/platform.tfstate" "${STUB_LOG}" || die "la key del estado no es la de stage"
grep -q -- "-backend-config=use_lockfile=true" "${STUB_LOG}" || die "falta el bloqueo nativo de S3"
if grep -q -- "dynamodb_table" "${STUB_LOG}"; then die "no debe usar la tabla DynamoDB (obsoleta)"; fi
grep -q -- "plan -no-color -lock-timeout=5m -detailed-exitcode -out=${WORK}/tf/stage.tfplan" "${STUB_LOG}" || die "plan no guarda stage.tfplan"
[[ -s "${WORK}/tf/stage-plan.txt" && -s "${WORK}/tf/stage-plan.json" ]] || die "faltan los reportes del plan"
if command -v jq >/dev/null 2>&1; then
  jq -e '.hasChanges == true and (.create | length) == 1' "${WORK}/tf/stage-summary.json" >/dev/null || die "resumen del plan incorrecto"
fi
pass "plan: backend S3 con bloqueo nativo por ambiente, plan guardado y reportes txt/json (exit 2 = con cambios no falla)"

bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" apply --env stage >/dev/null
grep -q -- "apply -no-color -lock-timeout=5m -auto-approve ${WORK}/tf/stage.tfplan" "${STUB_LOG}" || die "apply no usa el plan guardado"
pass "apply: aplica exactamente el plan guardado"

set +e; bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" apply --env prod >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 3 ]] || die "apply sin plan previo debería salir con 3 (obtuvo ${rc})"
set +e; bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" plan --env qa >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 1 ]] || die "ambiente inválido debería salir con 1"
pass "apply sin plan revisado se rechaza (3) y un ambiente inválido también (1)"

# Jenkins sin CG_TF_STATE_BUCKET dejaba el texto "null"; el bucket debe salir de la cuenta.
printf '#!/usr/bin/env bash\necho 123456789012\n' > "${WORK}/bin/aws"; chmod +x "${WORK}/bin/aws"
: > "${STUB_LOG}"
TF_STATE_BUCKET="null" bash "${ROOT}/infra/terraform/scripts/tf-pipeline.sh" plan --env dev >/dev/null
grep -q -- "-backend-config=bucket=circleguard-terraform-state-123456789012" "${STUB_LOG}" \
  || die "con TF_STATE_BUCKET=null debe deducir el bucket de la cuenta"
pass "plan: TF_STATE_BUCKET vacío o 'null' usa circleguard-terraform-state-<ID_CUENTA>"

echo "== trivy-scan.sh (US-38)"
export REPORT_DIR="${WORK}/trivy" TRIVY_TEMPLATES_DIR="${WORK}/tpl"
mkdir -p "${TRIVY_TEMPLATES_DIR}" && : > "${TRIVY_TEMPLATES_DIR}/junit.tpl"
: > "${STUB_LOG}"
bash "${ROOT}/infra/scripts/trivy-scan.sh" config --target infra/terraform --target no/existe >/dev/null
grep -q "trivy config --severity HIGH,CRITICAL --exit-code 1 --ignorefile ${ROOT}/.trivyignore --format table" "${STUB_LOG}" \
  || die "trivy config no usa HIGH,CRITICAL + exit-code 1 + .trivyignore"
[[ -f "${WORK}/trivy/junit/config-infra-terraform.xml" ]] || die "falta el JUnit del escaneo de IaC"
grep -q '"target":"no/existe","kind":"config","result":"SKIPPED"' "${WORK}/trivy/summary-config.json" || die "un directorio inexistente debería omitirse"
pass "config: severidad HIGH,CRITICAL bloqueante, .trivyignore, JUnit y directorios ausentes omitidos"

: > "${STUB_LOG}"
set +e
TRIVY_STUB_FAIL="gateway" REGISTRY_USER=u REGISTRY_PASSWORD=p \
  bash "${ROOT}/infra/scripts/trivy-scan.sh" image --version 1.4.0 --registry reg:5000 >/dev/null 2>&1
rc=$?
set -e
[[ ${rc} -eq 1 ]] || die "una imagen con HIGH/CRITICAL debería romper el build (obtuvo ${rc})"
[[ "$(grep -c -- '--format table' "${STUB_LOG}")" -eq 9 ]] || die "deben escanearse las 9 imágenes aunque una falle"
grep -q -- "--image-src docker,remote --ignore-unfixed --insecure" "${STUB_LOG}" || die "faltan las opciones de imagen local/registro HTTP"
grep -q "reg:5000/circleguard/mobile:1.4.0" "${STUB_LOG}" || die "no escaneó el cliente web"
grep -q '"target":"image-gateway","kind":"image","result":"FAIL"' "${WORK}/trivy/summary-image.json" || die "el resumen no marca gateway como FAIL"
pass "image: escanea las 9 imágenes, termina el reporte y sale con 1 si una tiene HIGH/CRITICAL"

rm -f "${WORK}/trivy/image-gateway.json"
set +e
TRIVY_STUB_FAIL="gateway" TRIVY_IMAGE_REPORT_ONLY=true \
  bash "${ROOT}/infra/scripts/trivy-scan.sh" image --version 1.4.0 --registry reg:5000 >/dev/null 2>&1
rc=$?
set -e
[[ ${rc} -eq 0 ]] || die "con TRIVY_IMAGE_REPORT_ONLY=true las imágenes no deberían romper el build (obtuvo ${rc})"
[[ -f "${WORK}/trivy/image-gateway.json" ]] || die "en modo reporte también debe generarse el JSON"
grep -q '"enforced":false' "${WORK}/trivy/summary-image.json" || die "el resumen debería marcar enforced=false"
grep -q '"target":"image-gateway","kind":"image","result":"FAIL"' "${WORK}/trivy/summary-image.json" || die "el resumen debería seguir marcando gateway como FAIL"
pass "image: TRIVY_IMAGE_REPORT_ONLY=true reporta los hallazgos sin bloquear"

set +e
TRIVY_STUB_FAIL="terraform" TRIVY_IMAGE_REPORT_ONLY=true \
  bash "${ROOT}/infra/scripts/trivy-scan.sh" config --target infra/terraform >/dev/null 2>&1
rc=$?
set -e
[[ ${rc} -eq 1 ]] || die "el escaneo IaC debe seguir bloqueando aunque TRIVY_IMAGE_REPORT_ONLY=true (obtuvo ${rc})"
pass "config: sigue bloqueando con TRIVY_IMAGE_REPORT_ONLY=true"

set +e; bash "${ROOT}/infra/scripts/trivy-scan.sh" image --version latest >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -ne 0 ]] || die "'latest' debería rechazarse"
pass "image: rechaza 'latest'"

echo "== k8s-deploy.sh (US-39 / US-28)"
OV="${WORK}/overlay"; mkdir -p "${OV}"
cat > "${OV}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: circleguard-dev
resources: [app.yaml]
EOF
cat > "${OV}/app.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: gateway-service, labels: {app.kubernetes.io/part-of: circleguard}}
spec:
  selector: {matchLabels: {app: gateway}}
  template:
    metadata: {labels: {app: gateway}}
    spec:
      containers:
        - {name: gateway, image: "circleguard/gateway-service:0.0.1"}
        - {name: db, image: "postgres:16.4-alpine"}
EOF
out="$(K8S_OVERLAY_DIR="${OV}" REGISTRY_URL=reg:5000 BUILD_NUMBER=42 \
       bash "${ROOT}/deploy/scripts/k8s-deploy.sh" deploy --env dev --version 1.4.0 --dry-run)"
REL="${ROOT}/build/k8s-release/dev/kustomization.yaml"
grep -q 'newName: reg:5000/circleguard/gateway-service' "${REL}" || die "la kustomization no fija el registro"
grep -q 'newTag: "1.4.0"' "${REL}" || die "la kustomization no fija la versión"
[[ "${out}" == *"kubectl apply -k ${ROOT}/build/k8s-release/dev"* ]] || die "no aplica con kubectl apply -k"
[[ "${out}" == *"change-cause=CircleGuard\ 1.4.0\ build\ 42"* ]] || die "no anota el change-cause"
if command -v kubectl >/dev/null 2>&1; then
  rendered="$(kubectl kustomize "${ROOT}/build/k8s-release/dev")"
  [[ "${rendered}" == *"image: reg:5000/circleguard/gateway-service:1.4.0"* ]] || die "el render no usa la imagen SemVer"
  [[ "${rendered}" == *"image: postgres:16.4-alpine"* ]] || die "el render cambió imágenes de terceros"
  pass "deploy: kubectl kustomize renderiza reg:5000/circleguard/gateway-service:1.4.0 y respeta postgres"
fi
pass "deploy: kustomization de release con la versión SemVer, apply -k y change-cause"

out="$(bash "${ROOT}/deploy/scripts/k8s-deploy.sh" verify --env stage --version 1.4.0 --dry-run)"
[[ "${out}" == *"-n circleguard-stage rollout status"* ]] || die "verify no usa rollout status en circleguard-stage"
out="$(bash "${ROOT}/deploy/scripts/k8s-deploy.sh" rollback --env prod --dry-run)"
[[ "${out}" == *"-n circleguard-prod rollout undo"* ]] || die "rollback no usa rollout undo"
pass "verify usa rollout status y rollback usa rollout undo en el namespace del ambiente (US-28)"

set +e; bash "${ROOT}/deploy/scripts/k8s-deploy.sh" deploy --env dev --version latest --dry-run >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 1 ]] || die "'latest' debería rechazarse"
set +e; K8S_OVERLAY_DIR="${WORK}/nada" bash "${ROOT}/deploy/scripts/k8s-deploy.sh" deploy --env dev --version 1.4.0 --dry-run >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 2 ]] || die "sin overlay debería salir con 2 (obtuvo ${rc})"
pass "rechaza 'latest' (1) y un overlay inexistente (2)"

echo "== zap-scan.sh (US-44)"
# docker simulado: el cp desde /zap/wrk deja un reporte JSON; ZAP_STUB_HIGH marca un objetivo con riesgo alto.
cat > "${WORK}/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG}"
# cp -a - <contenedor>:/zap/ recibe la carpeta wrk como tar por stdin: se guarda su listado.
[[ "$1" == cp && "$2" == -a && "$3" == - ]] && tar -tvf - >> "${STUB_LOG}.tar"
if [[ "$1" == cp && "$2" == *:/zap/wrk/. ]]; then
  t="${2#zap-us44-*-}"; t="${t%%-*}"; risk=1
  [[ "${t}" == "${ZAP_STUB_HIGH:-}" ]] && risk=3
  printf '{"site":[{"alerts":[{"riskcode": "%s"},{"riskcode": "2"}]}]}' "${risk}" > "$3/${t}.json"
fi
exit 0
STUB
chmod +x "${WORK}/bin/docker"
: > "${STUB_LOG}"; : > "${STUB_LOG}.tar"
ZAP="${ROOT}/infra/scripts/zap-scan.sh"
REPORT_DIR="${WORK}/zap" ZAP_DOCKER_NETWORK=host bash "${ZAP}" --env dev --local >/dev/null 2>&1 || die "sin alertas altas debería salir con 0"
grep -q 'zap-baseline.py -t http://127.0.0.1:8080/ -m 2 -I -r web.html -J web.json -w web.md' "${STUB_LOG}" || die "no escanea el cliente web de dev"
grep -q -- '-t http://127.0.0.1:8180/' "${STUB_LOG}" && grep -q -- '-t http://127.0.0.1:8087/' "${STUB_LOG}" || die "no escanea auth y gateway"
grep -q 'docker cp -a - zap-us44-dev-web-.*:/zap/' "${STUB_LOG}" || die "no copia la carpeta wrk al contenedor"
grep -Eq '1000 +1000 .* wrk/baseline-rules.tsv|1000/1000 .* wrk/baseline-rules.tsv' "${STUB_LOG}.tar" \
  || die "wrk no lleva .zap/baseline-rules.tsv con dueño 1000:1000 (el usuario zap no podría escribir)"
grep -q '"result": "PASS"' "${WORK}/zap/summary.json" || die "summary.json no reporta PASS"
[[ -s "${WORK}/zap/junit/web.xml" ]] || die "falta el JUnit de web"
pass "local: escanea web, auth y gateway con las reglas del repo en un wrk de 1000:1000 y deja summary.json y JUnit"

set +e; ZAP_STUB_HIGH=gateway REPORT_DIR="${WORK}/zap-high" ZAP_DOCKER_NETWORK=host bash "${ZAP}" --env stage --local >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 1 ]] || die "una alerta de riesgo alto debería salir con 1 (obtuvo ${rc})"
grep -q -- '-t http://127.0.0.1:9087/' "${STUB_LOG}" || die "stage no usa los puertos con offset 1000"
grep -q 'failures="1"' "${WORK}/zap-high/junit/gateway.xml" || die "el JUnit no marca el hallazgo alto"
ZAP_STUB_HIGH=gateway ZAP_MAX_HIGH=1 REPORT_DIR="${WORK}/zap-max" ZAP_DOCKER_NETWORK=host bash "${ZAP}" --env stage --local >/dev/null 2>&1 || die "ZAP_MAX_HIGH=1 debería tolerar una alerta alta"
pass "política: riesgo alto sobre ZAP_MAX_HIGH sale con 1; stage usa los puertos con offset"

out="$(DRY_RUN=1 SSH_KEY=/llave REPORT_DIR="${WORK}/zap-ssh" bash "${ZAP}" --env dev --host 10.0.0.5 2>&1)"
[[ "${out}" == *"-L 127.0.0.1:38080:127.0.0.1:8080"* && "${out}" == *"ec2-user@10.0.0.5"* ]] || die "no arma el túnel SSH hacia el nodo"
set +e; bash "${ZAP}" --env prod --local >/dev/null 2>&1; rc=$?; set -e
[[ ${rc} -eq 2 ]] || die "prod debería rechazarse (2)"
pass "remoto: túnel SSH como run-e2e.sh; prod se rechaza (2)"

# Sin kubectl en el PATH usa el binario fijo de lib.sh (aquí uno simulado ya descargado).
TOOLS="${WORK}/tools"; mkdir -p "${TOOLS}" "${WORK}/nobin"
printf '#!/usr/bin/env bash\necho "kubectl-cache $*" >> "%s"\n' "${STUB_LOG}" > "${TOOLS}/kubectl-v1.32.2"
chmod +x "${TOOLS}/kubectl-v1.32.2"
for t in bash cat dirname uname tail sed mkdir; do ln -sf "$(command -v "$t")" "${WORK}/nobin/$t"; done
: > "${STUB_LOG}"
PATH="${WORK}/nobin" CG_TOOLS_DIR="${TOOLS}" KUBECONFIG="${WORK}/kubeconfig" \
  bash "${ROOT}/deploy/scripts/k8s-deploy.sh" status --env dev >/dev/null
grep -q "kubectl-cache -n circleguard-dev get" "${STUB_LOG}" || die "sin kubectl en el PATH no usa el de lib.sh"
pass "deploy/verify: sin kubectl en el PATH usa la versión fija de deploy/k8s/scripts/lib.sh"

echo "=== RESULTADO: OK — ${PASS} pruebas de plataforma superadas ==="
