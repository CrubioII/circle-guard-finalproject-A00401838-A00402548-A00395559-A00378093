"""
US-27 (SCRUM-96): pruebas de carga y estrés de CircleGuard con Locust.

Simula los flujos con más tráfico real del campus contra un ambiente desplegado:

- CampusEntryUser (peso 6): ingreso al campus. Pide un QR a auth-service y lo
  valida en gateway-service, como hace el torniquete en la entrada.
- SurveyUser (peso 3): envía el cuestionario diario de salud a form-service.
- AdminStatsUser (peso 1): consulta las estadísticas de salud de promotion-service.

Las URLs, el usuario y los umbrales salen de variables de entorno (ver README.md).
Al terminar, la corrida falla (código 1) si supera los umbrales de p95 o de error,
para que el pipeline o quien la corra lo note sin leer el reporte.
"""

import logging
import os
import uuid

from locust import HttpUser, between, events, task


def _url(name, default):
    return os.getenv(name, default).rstrip("/")


AUTH_URL = _url("AUTH_URL", "http://127.0.0.1:8180")
GATEWAY_URL = _url("GATEWAY_URL", "http://127.0.0.1:8087")
FORM_URL = _url("FORM_URL", "http://127.0.0.1:8086")
PROMOTION_URL = _url("PROMOTION_URL", "http://127.0.0.1:8088")

# Usuario sembrado por la migración V2__seed_test_users.sql de auth-service (el mismo de los E2E).
USERNAME = os.getenv("LOCUST_USERNAME", "staff_guard")
PASSWORD = os.getenv("LOCUST_PASSWORD", "password")

# Umbrales: p95 global, p95 de la validación en la puerta (el flujo crítico) y tasa de error.
P95_MS = float(os.getenv("P95_MS", "800"))
GATE_P95_MS = float(os.getenv("GATE_P95_MS", "300"))
MAX_ERROR_RATE = float(os.getenv("MAX_ERROR_RATE", "0.01"))

GATE_VALIDATE = "/api/v1/gate/validate"


def login(client):
    """Inicia sesión en auth-service y devuelve el JWT, o None si falla."""
    with client.post(
        f"{AUTH_URL}/api/v1/auth/login",
        json={"username": USERNAME, "password": PASSWORD},
        name="/api/v1/auth/login",
        catch_response=True,
    ) as response:
        if response.status_code != 200:
            response.failure(f"login respondió {response.status_code}")
            return None
        token = response.json().get("token")
        if not token:
            response.failure("login sin token")
        return token


class CampusEntryUser(HttpUser):
    """Torniquete del campus: QR emitido por auth y validado por gateway."""

    weight = 6
    host = AUTH_URL
    wait_time = between(1, 3)

    def on_start(self):
        self.jwt = login(self.client)

    @task(5)
    def enter_campus(self):
        if not self.jwt:
            self.jwt = login(self.client)
            return
        with self.client.get(
            f"{AUTH_URL}/api/v1/auth/qr/generate",
            headers={"Authorization": f"Bearer {self.jwt}"},
            name="/api/v1/auth/qr/generate",
            catch_response=True,
        ) as response:
            if response.status_code in (401, 403):
                # JWT vencido: se renueva en la siguiente iteración
                response.failure(f"QR rechazado ({response.status_code}), se renueva la sesión")
                self.jwt = None
                return
            if response.status_code != 200:
                response.failure(f"generar QR respondió {response.status_code}")
                return
            qr_token = response.json().get("qrToken")

        with self.client.post(
            f"{GATEWAY_URL}/api/v1/gate/validate",
            json={"token": qr_token},
            name=GATE_VALIDATE,
            catch_response=True,
        ) as response:
            if response.status_code != 200:
                response.failure(f"validar QR respondió {response.status_code}")
            elif response.json().get("valid") is not True:
                response.failure(f"QR válido rechazado: {response.text[:120]}")

    @task(1)
    def login_again(self):
        # Inicios de sesión durante la jornada (cambio de turno, app reinstalada)
        self.jwt = login(self.client)


class SurveyUser(HttpUser):
    """Cuestionario diario de salud. Usa IDs anónimos nuevos y sin síntomas."""

    weight = 3
    host = FORM_URL
    wait_time = between(2, 5)

    @task
    def submit_survey(self):
        survey = {
            "anonymousId": str(uuid.uuid4()),
            "hasFever": False,
            "hasCough": False,
            "otherSymptoms": "",
            "responses": {"source": "locust-us27"},
        }
        with self.client.post(
            f"{FORM_URL}/api/v1/surveys",
            json=survey,
            name="/api/v1/surveys",
            catch_response=True,
        ) as response:
            if response.status_code not in (200, 201):
                response.failure(f"cuestionario respondió {response.status_code}")


class AdminStatsUser(HttpUser):
    """Personal administrativo consultando el tablero de salud."""

    weight = 1
    host = PROMOTION_URL
    wait_time = between(3, 6)

    @task
    def health_stats(self):
        self.client.get(f"{PROMOTION_URL}/api/v1/health-status/stats", name="/api/v1/health-status/stats")


@events.quitting.add_listener
def check_thresholds(environment, **_kwargs):
    """Falla la corrida si el p95 o la tasa de error superan los umbrales."""
    stats = environment.stats
    total = stats.total
    problems = []

    if total.num_requests == 0:
        problems.append("no se ejecutó ninguna petición")
    else:
        p95 = total.get_response_time_percentile(0.95)
        if p95 > P95_MS:
            problems.append(f"p95 global {p95:.0f} ms > {P95_MS:.0f} ms")
        if total.fail_ratio > MAX_ERROR_RATE:
            problems.append(f"tasa de error {total.fail_ratio:.2%} > {MAX_ERROR_RATE:.2%}")

        gate = stats.entries.get((GATE_VALIDATE, "POST"))
        if gate and gate.num_requests:
            gate_p95 = gate.get_response_time_percentile(0.95)
            if gate_p95 > GATE_P95_MS:
                problems.append(f"p95 de la puerta {gate_p95:.0f} ms > {GATE_P95_MS:.0f} ms")

        logging.info(
            "[US-27] %d peticiones, %.1f req/s, p95 %.0f ms, error %.2f%%",
            total.num_requests, total.total_rps, total.get_response_time_percentile(0.95), total.fail_ratio * 100,
        )

    if problems:
        logging.error("[US-27] Umbrales superados: %s", "; ".join(problems))
        environment.process_exit_code = 1
    else:
        logging.info("[US-27] Umbrales cumplidos (p95 <= %.0f ms, puerta <= %.0f ms, error <= %.2f%%)",
                     P95_MS, GATE_P95_MS, MAX_ERROR_RATE * 100)
        environment.process_exit_code = 0
