package com.circleguard.auth.client;

/**
 * identity-service no respondió tras los reintentos o el Circuit Breaker está abierto
 * (US-23 / SCRUM-92). El login responde 503 para que el cliente reintente más tarde.
 */
public class IdentityServiceUnavailableException extends RuntimeException {

    public IdentityServiceUnavailableException(Throwable cause) {
        super("identity-service no disponible", cause);
    }
}
