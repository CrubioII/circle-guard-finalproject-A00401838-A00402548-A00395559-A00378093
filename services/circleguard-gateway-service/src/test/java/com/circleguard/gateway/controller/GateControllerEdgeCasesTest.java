package com.circleguard.gateway.controller;

import com.circleguard.gateway.service.QrValidationService;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.http.ResponseEntity;

import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * US-32: el controlador delega el token tal cual al servicio, incluso cuando falta.
 */
class GateControllerEdgeCasesTest {

    @Test
    void shouldReturnDeniedResultFromService() {
        QrValidationService service = Mockito.mock(QrValidationService.class);
        QrValidationService.ValidationResult denied =
                new QrValidationService.ValidationResult(false, "RED", "Access Denied: Health Risk Detected");
        Mockito.when(service.validateToken("bad")).thenReturn(denied);

        ResponseEntity<QrValidationService.ValidationResult> response =
                new GateController(service).validate(Map.of("token", "bad"));

        assertEquals(200, response.getStatusCode().value());
        assertSame(denied, response.getBody());
    }

    @Test
    void shouldPassNullWhenTokenIsMissing() {
        QrValidationService service = Mockito.mock(QrValidationService.class);
        QrValidationService.ValidationResult invalid =
                new QrValidationService.ValidationResult(false, "RED", "Invalid or Expired Token");
        Mockito.when(service.validateToken(null)).thenReturn(invalid);

        ResponseEntity<QrValidationService.ValidationResult> response =
                new GateController(service).validate(new HashMap<>());

        assertFalse(response.getBody().valid());
        Mockito.verify(service).validateToken(null);
    }
}
