package com.circleguard.notification.service;

import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;

/**
 * US-32: sincronización con el LMS sin levantar el contexto Spring.
 */
class LmsServiceImplTest {

    @Test
    void syncCompletesImmediately() {
        LmsServiceImpl service = new LmsServiceImpl();
        ReflectionTestUtils.setField(service, "lmsApiUrl", "https://lms.test/api");
        ReflectionTestUtils.setField(service, "identityApiUrl", "http://identity.test");

        CompletableFuture<Void> future = service.syncRemoteAttendance("12345678-aaaa-bbbb", "SUSPECT");

        assertTrue(future.isDone());
        assertFalse(future.isCompletedExceptionally());
    }
}
