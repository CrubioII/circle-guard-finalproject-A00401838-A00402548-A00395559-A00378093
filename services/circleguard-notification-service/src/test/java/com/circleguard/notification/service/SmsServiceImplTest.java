package com.circleguard.notification.service;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * US-32: canal SMS en modo mock (sin credenciales Twilio reales) y recuperación tras reintentos.
 */
class SmsServiceImplTest {

    private SmsServiceImpl service;
    private AuditLogService auditLogService;

    @BeforeEach
    void setUp() {
        service = new SmsServiceImpl();
        auditLogService = mock(AuditLogService.class);
        ReflectionTestUtils.setField(service, "accountSid", "AC_MOCK_SID");
        ReflectionTestUtils.setField(service, "authToken", "MOCK_TOKEN");
        ReflectionTestUtils.setField(service, "fromNumber", "+15550000000");
        ReflectionTestUtils.setField(service, "auditLogService", auditLogService);
    }

    @Test
    void initSkipsTwilioWithMockCredentials() {
        assertDoesNotThrow(service::init);
    }

    @Test
    void mockModeAuditsSuccessWithoutCallingTwilio() {
        CompletableFuture<Void> future = service.sendAsync("anon-1", "status changed");

        assertTrue(future.isDone());
        assertFalse(future.isCompletedExceptionally());
        verify(auditLogService).logDelivery(eq("anon-1"), eq("SMS"), eq("SUCCESS"), anyString());
    }

    @Test
    void realModeFailureAuditsRetryAndRethrows() {
        // Sin Twilio.init el SDK falla al crear el mensaje, lo que ejercita la rama de error.
        ReflectionTestUtils.setField(service, "accountSid", "AC_REAL_BUT_NOT_INITIALIZED");

        assertThrows(Exception.class, () -> service.sendAsync("anon-1", "status changed"));
        verify(auditLogService).logDelivery(eq("anon-1"), eq("SMS"), eq("RETRY"), anyString());
    }

    @Test
    void recoverAuditsFailure() {
        CompletableFuture<Void> future = service.recover(new RuntimeException("x"), "anon-1", "msg");

        assertTrue(future.isCompletedExceptionally());
        verify(auditLogService).logDelivery("anon-1", "SMS", "FAILED", null);
    }
}
